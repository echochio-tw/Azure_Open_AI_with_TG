package handlers

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"merged-go-bot/config"
	"merged-go-bot/models"
	"merged-go-bot/services"
)

type MergedHandler struct {
	cfg       *config.Config
	redisSvc  *services.RedisService
	openaiSvc *services.OpenAIService
	soraSvc   *services.SoraService
	bot       *tgbotapi.BotAPI
}

func NewMergedHandler(
	cfg *config.Config,
	redisSvc *services.RedisService,
	openaiSvc *services.OpenAIService,
	soraSvc *services.SoraService,
	bot *tgbotapi.BotAPI,
) *MergedHandler {
	return &MergedHandler{
		cfg:       cfg,
		redisSvc:  redisSvc,
		openaiSvc: openaiSvc,
		soraSvc:   soraSvc,
		bot:       bot,
	}
}

func (h *MergedHandler) HandleTelegramWebhook(w http.ResponseWriter, r *http.Request) {
	expectedPath := "/telegram_webhook/" + h.cfg.TelegramBotToken
	if r.URL.Path != expectedPath {
		log.Printf("Webhook path mismatch. Expected: %s, Got: %s", expectedPath, r.URL.Path)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var update tgbotapi.Update
	if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
		log.Printf("解析 Telegram update 失敗: %v", err)
		return
	}

	if update.Message == nil {
		w.WriteHeader(http.StatusOK)
		return
	}
	
	message := update.Message
	chatID := message.Chat.ID
	text := message.Text

	roomConfig, err := h.redisSvc.GetRoomConfig(chatID)
	if err != nil {
		log.Printf("從 Redis 獲取聊天室配置失敗: %v", err)
		w.WriteHeader(http.StatusOK)
		return
	}
	if roomConfig == nil || !roomConfig.Approved {
		h.bot.Send(tgbotapi.NewMessage(chatID, "此聊天室未被授權使用 AI 功能。請聯繫管理員。"))
		w.WriteHeader(http.StatusOK)
		return
	}

	if strings.HasPrefix(text, "/get ") {
		h.handleGetCommand(chatID, text)
	} else if strings.HasPrefix(text, "/video ") {
		h.handleVideoCommand(chatID, text)
	} else if message.IsCommand() {
		h.handleGeneralCommands(chatID, message.Command())
	} else if text != "" {
		h.handleChatCompletion(chatID, text)
	}
	
	w.WriteHeader(http.StatusOK)
}

func (h *MergedHandler) handleGeneralCommands(chatID int64, command string) {
	switch command {
	case "start":
		msg := tgbotapi.NewMessage(chatID, "歡迎使用，請輸入您想問的內容，或使用 `/get [提示詞]` 進行一次性查詢，或 `/video [提示詞]` 生成影片。")
		h.bot.Send(msg)
	case "clear":
		h.redisSvc.ClearMessages(chatID)
		msg := tgbotapi.NewMessage(chatID, "聊天歷史已清除。")
		h.bot.Send(msg)
	default:
	}
}

func (h *MergedHandler) handleGetCommand(chatID int64, text string) {
	prompt := strings.TrimSpace(strings.TrimPrefix(text, "/get"))
	if prompt == "" {
		h.bot.Send(tgbotapi.NewMessage(chatID, "請在 `/get` 後面加上您想問的問題。"))
		return
	}
	
	// 修正: 始終使用預設部署名稱
	deploymentName := h.cfg.DefaultOpenAIDeploymentName
	if deploymentName == "" {
		log.Printf("錯誤：預設模型部署名稱為空，無法處理 /get 請求。")
		h.bot.Send(tgbotapi.NewMessage(chatID, "預設模型部署名稱未設定，無法處理您的請求。請檢查 `.env` 檔案。"))
		return
	}

	messages := []models.Message{
		{Role: "user", Content: prompt},
	}
	
	response, err := h.openaiSvc.GetChatCompletion("", deploymentName, messages)
	if err != nil {
		log.Printf("從 OpenAI 獲取回應失敗: %v", err)
		h.bot.Send(tgbotapi.NewMessage(chatID, "從 AI 獲取回應時發生錯誤。"))
		return
	}
	
	h.bot.Send(tgbotapi.NewMessage(chatID, response))
}

func (h *MergedHandler) handleChatCompletion(chatID int64, text string) {
	messages, err := h.redisSvc.GetMessages(chatID)
	if err != nil {
		log.Printf("獲取聊天歷史失敗: %v", err)
		return
	}
	messages = append(messages, models.Message{Role: "user", Content: text})
	
	deploymentName := h.cfg.DefaultOpenAIDeploymentName
	if deploymentName == "" {
		log.Printf("錯誤：預設模型部署名稱為空，無法處理聊天請求。")
		h.bot.Send(tgbotapi.NewMessage(chatID, "預設模型部署名稱未設定，無法處理您的請求。請檢查 `.env` 檔案。"))
		return
	}

	trimmedMessages, _ := h.openaiSvc.TrimMessages(deploymentName, messages)
	
	response, err := h.openaiSvc.GetChatCompletion("", deploymentName, trimmedMessages)
	if err != nil {
		log.Printf("從 OpenAI 獲取回應失敗: %v", err)
		h.bot.Send(tgbotapi.NewMessage(chatID, "從 AI 獲取回應時發生錯誤。"))
		return
	}
	messages = append(messages, models.Message{Role: "assistant", Content: response})
	h.redisSvc.SaveMessages(chatID, messages)
	
	msg := tgbotapi.NewMessage(chatID, response)
	h.bot.Send(msg)
}

func (h *MergedHandler) handleVideoCommand(chatID int64, text string) {
	prompt := strings.TrimSpace(strings.TrimPrefix(text, "/video"))
	if prompt == "" {
		h.bot.Send(tgbotapi.NewMessage(chatID, "請在 `/video` 後面加上影片描述。"))
		return
	}
	
	log.Printf("收到影片生成請求，提示詞：\"%s\"", prompt)
	filePath, err := h.soraSvc.GenerateVideo(chatID, prompt)
	if err != nil {
		log.Printf("影片生成失敗: %v", err)
		h.bot.Send(tgbotapi.NewMessage(chatID, fmt.Sprintf("影片生成失敗: %v", err)))
		return
	}
	
	videoFile, err := os.Open(filePath)
	if err != nil {
		log.Printf("開啟影片檔案失敗: %v", err)
		h.bot.Send(tgbotapi.NewMessage(chatID, "無法開啟生成的影片檔案。"))
		return
	}
	defer videoFile.Close()

	videoBytes, err := io.ReadAll(videoFile)
	if err != nil {
		log.Printf("讀取影片檔案失敗: %v", err)
		h.bot.Send(tgbotapi.NewMessage(chatID, "無法讀取生成的影片檔案。"))
		return
	}
	
	file := tgbotapi.FileBytes{
		Name:  filepath.Base(filePath),
		Bytes: videoBytes,
	}
	
	videoMsg := tgbotapi.NewVideo(chatID, file)
	_, err = h.bot.Send(videoMsg)
	if err != nil {
		log.Printf("發送影片失敗: %v", err)
		h.bot.Send(tgbotapi.NewMessage(chatID, "發送影片失敗。"))
	}
	
	os.Remove(filePath)
	log.Printf("已刪除臨時影片檔案：%s", filePath)
}