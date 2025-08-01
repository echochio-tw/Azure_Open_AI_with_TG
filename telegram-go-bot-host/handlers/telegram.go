package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"telegram-go-bot-host/config"
	"telegram-go-bot-host/models"
	"telegram-go-bot-host/services"
)

type TelegramWebhookHandler struct {
	bot        *tgbotapi.BotAPI
	cfg        *config.Config
	redisSvc   *services.RedisService
	openaiSvc  *services.OpenAIService
}

func NewTelegramWebhookHandler(
	bot *tgbotapi.BotAPI,
	cfg *config.Config,
	redisSvc *services.RedisService,
	openaiSvc *services.OpenAIService,
) *TelegramWebhookHandler {
	return &TelegramWebhookHandler{
		bot:        bot,
		cfg:        cfg,
		redisSvc:   redisSvc,
		openaiSvc:  openaiSvc,
	}
}

func (h *TelegramWebhookHandler) HandleUpdate(w http.ResponseWriter, r *http.Request) {
	expectedPath := "/telegram_webhook/" + h.cfg.TelegramBotToken
	if r.URL.Path != expectedPath {
		log.Printf("Webhook path mismatch. Expected: %s, Got: %s", expectedPath, r.URL.Path)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var update tgbotapi.Update
	if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
		log.Printf("無法解碼 Telegram 更新: %v", err)
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}

	if update.Message == nil {
		w.WriteHeader(http.StatusOK)
		return
	}

	log.Printf("[%s] %s", update.Message.From.UserName, update.Message.Text)

	chatID := update.Message.Chat.ID
	userName := update.Message.From.UserName
	messageText := strings.TrimSpace(update.Message.Text)

	if strings.HasPrefix(messageText, "/start") {
		h.handleStartCommand(chatID, userName)
		w.WriteHeader(http.StatusOK)
		return
	}
	
	// 在這裡移除了舊的處理群組訊息提及的邏輯，現在機器人會回應所有群組訊息。
	// 新增的邏輯：移除 "/get " 前綴
	if strings.HasPrefix(messageText, "/get ") {
		messageText = strings.TrimPrefix(messageText, "/get ")
		messageText = strings.TrimSpace(messageText)
		log.Printf("已移除 '/get ' 前綴。傳遞給 AI 的訊息: \"%s\"", messageText)
	}


	log.Printf("正在獲取聊天室 %d 的配置...", chatID)
	roomConfig, err := h.redisSvc.GetRoomConfig(chatID)
	if err != nil {
		log.Printf("錯誤：無法獲取聊天室 %d 的配置: %v", chatID, err)
		h.sendMessage(chatID, "發生內部錯誤，請稍後再試。")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	if roomConfig == nil || !roomConfig.Approved || roomConfig.APIKey == "" {
		response := "此聊天室尚未啟用 AI 功能，請聯繫管理員審批。\n" +
			"如果您是管理員，請確認該聊天室的配置已在 Redis 中設置為 `approved: true`。"
		log.Printf("聊天室 %d 配置未獲批或 API 金鑰缺失。RoomConfig: %+v", chatID, roomConfig)
		h.sendMessage(chatID, response)
		w.WriteHeader(http.StatusOK)
		return
	}
	log.Printf("聊天室 %d 配置已載入。Approved: %t, Model: %s", chatID, roomConfig.Approved, roomConfig.ModelName)


	log.Printf("正在獲取聊天室 %d 的歷史訊息...", chatID)
	messages, err := h.redisSvc.GetMessages(chatID)
	if err != nil {
		log.Printf("錯誤：無法獲取聊天室 %d 的歷史訊息: %v", chatID, err)
		h.sendMessage(chatID, "發生內部錯誤，請稍後再試。")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	log.Printf("聊天室 %d 歷史訊息數量: %d", chatID, len(messages))


	messages = append(messages, models.Message{Role: "user", Content: messageText})
	log.Printf("已將使用者訊息新增到歷史紀錄。當前訊息總數: %d", len(messages))

	log.Printf("正在為模型 %s 修剪訊息...", roomConfig.ModelName)
	trimmedMessages, currentTokens := h.openaiSvc.TrimMessages(roomConfig.ModelName, messages)
	log.Printf("訊息修剪完成。修剪後訊息數量: %d, 總 Token: %d", len(trimmedMessages), currentTokens)

	maxTokens := h.openaiSvc.GetModelMaxTokens(roomConfig.ModelName)
	if float64(currentTokens) > float64(maxTokens)*h.cfg.TokenWarningThreshold {
		log.Printf("警告：聊天室 %d 的對話歷史已過長 (Token: %d/%d)，將提示使用者。", chatID, currentTokens, maxTokens)
		h.sendMessage(chatID, "ℹ️ 對話歷史已過長，為保證 AI 回應品質，將自動清除部分早期對話。")
	}

	log.Printf("正在呼叫 OpenAI 服務獲取回應 (ChatID: %d, Model: %s)...", chatID, roomConfig.ModelName)
	aiResponse, err := h.openaiSvc.GetChatCompletion(roomConfig.APIKey, roomConfig.ModelName, trimmedMessages)
	if err != nil {
		log.Printf("錯誤：獲取 AI 回應失敗 (ChatID: %d): %v", chatID, err)
		h.sendMessage(chatID, "AI 服務暫時不可用，請稍後再試或檢查配置。")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	log.Printf("成功從 OpenAI 收到回應 (ChatID: %d)。回應長度: %d", chatID, len(aiResponse))

	messages = append(messages, models.Message{Role: "assistant", Content: aiResponse})
	log.Printf("已將 AI 回應新增到歷史紀錄。總訊息數: %d", len(messages))

	log.Printf("正在保存聊天室 %d 的歷史訊息...", chatID)
	if err := h.redisSvc.SaveMessages(chatID, messages); err != nil {
		log.Printf("錯誤：無法保存聊天室 %d 的歷史訊息: %v", chatID, err)
	} else {
		log.Printf("成功保存聊天室 %d 的歷史訊息。", chatID)
	}

	log.Printf("正在發送 AI 回應到聊天室 %d...", chatID)
	h.sendMessage(chatID, aiResponse)
	log.Printf("已發送回應到聊天室 %d。", chatID)
	w.WriteHeader(http.StatusOK)
}

func (h *TelegramWebhookHandler) handleStartCommand(chatID int64, userName string) {
	log.Printf("處理 /start 命令 (ChatID: %d, User: %s)", chatID, userName)
	roomConfig, err := h.redisSvc.GetRoomConfig(chatID)
	if err != nil {
		log.Printf("處理 /start 命令時無法獲取聊天室 %d 的配置: %v", chatID, err)
		h.sendMessage(chatID, "處理您的請求時發生內部錯誤。")
		return
	}

	if roomConfig == nil {
		newConfig := &models.RoomConfig{
			ChatID:    chatID,
			Approved:  false,
			APIKey:    h.cfg.AzureOpenAIAPIKey,
			ModelName: h.cfg.DefaultOpenAIDeploymentName,
		}
		if err := h.redisSvc.SaveRoomConfig(newConfig); err != nil {
			log.Printf("保存新的聊天室 %d 配置失敗: %v", chatID, err)
			h.sendMessage(chatID, "無法初始化聊天室配置，請聯繫管理員。")
			return
		}
		log.Printf("新聊天室 %d (使用者: %s) 已註冊，等待管理員審批。", chatID, userName)
		response := fmt.Sprintf("您好 %s！此聊天室 ID 為 `%d`。\n", userName, chatID) +
			"請管理員透過後台 API 審批即可啟用 AI 功能。"
		h.sendMessage(chatID, response)
	} else if !roomConfig.Approved {
		log.Printf("聊天室 %d 尚未獲批 (處理 /start 命令)。", chatID)
		response := fmt.Sprintf("此聊天室 ID 為 `%d`。AI 功能尚未啟用。\n", chatID) +
			"請等待管理員審批。謝謝！"
		h.sendMessage(chatID, response)
	} else {
		log.Printf("聊天室 %d 已獲批 (處理 /start 命令)。模型: %s", chatID, roomConfig.ModelName)
		response := fmt.Sprintf("您好 %s！此聊天室 ID 為 `%d`。\n", userName, chatID) +
			"AI 功能已啟用！您可以開始和我對話了。\n" +
			"當前配置模型: `" + roomConfig.ModelName + "`。"
		h.sendMessage(chatID, response)
	}
}

func (h *TelegramWebhookHandler) sendMessage(chatID int64, text string) {
	msg := tgbotapi.NewMessage(chatID, text)
	msg.ParseMode = tgbotapi.ModeMarkdown
	_, err := h.bot.Send(msg)
	if err != nil {
		log.Printf("錯誤：無法發送訊息到聊天室 %d: %v", chatID, err)
	}
}
