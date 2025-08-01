#!/bin/bash
set -e

PROJECT_DIR="telegram-go-bot-sora"
GO_MODULE_NAME="telegram-go-bot-sora"

echo "正在創建專案目錄: $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR/config" \
         "$PROJECT_DIR/handlers" \
         "$PROJECT_DIR/models" \
         "$PROJECT_DIR/services" \
         "$PROJECT_DIR/tmp" # 用於存放臨時影片檔案

cd "$PROJECT_DIR" || exit

echo "正在生成 go.mod 檔案..."
cat > go.mod << EOF
module ${GO_MODULE_NAME}

go 1.23

require (
	github.com/go-telegram-bot-api/telegram-bot-api/v5 v5.5.1
	github.com/redis/go-redis/v9 v9.6.0
	github.com/joho/godotenv v1.5.1
)

require (
	github.com/cespare/xxhash/v2 v2.2.0 // indirect
	github.com/dgryski/go-rendezvous v0.0.0-20200823014737-9f7001d12a5f // indirect
	golang.org/x/net v0.27.0 // indirect
	golang.org/x/sys v0.22.0 // indirect
)
EOF

echo "正在生成 .env.example 檔案..."
cat > .env.example << "EOF"
TELEGRAM_BOT_TOKEN="8392952643:AAGnKkiTCtZtv26AYT6BDHGUxLtYW9Tf4og"
AZURE_OPENAI_ENDPOINT="https://admin-mdpgiszd-eastus2.cognitiveservices.azure.com/"

# 您的 Azure OpenAI API 金鑰，用於所有 Sora 影片生成請求
AZURE_OPENAI_API_KEY="Awk1yGxudejOGakAh"

# Sora 影片生成相關配置
AZURE_OPENAI_SORA_DEPLOYMENT_NAME="sora"
AZURE_OPENAI_SORA_API_VERSION="preview" # 根據官方文件，Sora API 版本為 'preview'

# Sora 影片尺寸和時長（可選，Sora 服務中可指定）
SORA_DEFAULT_WIDTH=1920
SORA_DEFAULT_HEIGHT=1080
SORA_DEFAULT_N_SECONDS=10 # 預設影片秒數

LISTEN_ADDR=":8081"
REDIS_ADDR="localhost:6379"
REDIS_PASSWORD=""
REDIS_DB=1 # 專用於此 Sora 機器人的 Redis DB
TELEGRAM_WEBHOOK_BASE_URL="https://your-public-domain.com"
EOF

echo "正在生成 config/config.go 檔案..."
cat > config/config.go << "EOF"
package config

import (
	"log"
	"os"
	"strconv"
)

type Config struct {
	TelegramBotToken            string
	TelegramWebhookPath         string
	TelegramWebhookURL          string
	ListenAddr                  string
	RedisAddr                   string
	RedisPassword               string
	RedisDB                     int
	AzureOpenAIEndpoint         string
	AzureOpenAIAPIKey           string // 統一用於所有 Azure OpenAI 服務，包括 Sora
	// Sora 相關配置
	AzureOpenAISoraDeploymentName string
	AzureOpenAISoraAPIVersion     string
	SoraDefaultWidth              int
	SoraDefaultHeight             int
	SoraDefaultNSeconds           int
}

func LoadConfig() *Config {
	cfg := &Config{
		TelegramBotToken:            os.Getenv("TELEGRAM_BOT_TOKEN"),
		TelegramWebhookPath:         "/telegram_webhook/" + os.Getenv("TELEGRAM_BOT_TOKEN"),
		ListenAddr:                  os.Getenv("LISTEN_ADDR"),
		RedisAddr:                   os.Getenv("REDIS_ADDR"),
		RedisPassword:               os.Getenv("REDIS_PASSWORD"),
		AzureOpenAIEndpoint:         os.Getenv("AZURE_OPENAI_ENDPOINT"),
		AzureOpenAIAPIKey:           os.Getenv("AZURE_OPENAI_API_KEY"),
		// 載入 Sora 配置
		AzureOpenAISoraDeploymentName: os.Getenv("AZURE_OPENAI_SORA_DEPLOYMENT_NAME"),
		AzureOpenAISoraAPIVersion:     os.Getenv("AZURE_OPENAI_SORA_API_VERSION"),
	}

	if cfg.TelegramBotToken == "" {
		log.Fatal("錯誤：TELEGRAM_BOT_TOKEN 環境變數未設定。請檢查您的 .env 檔案。")
	}
	if cfg.AzureOpenAIEndpoint == "" {
		log.Fatal("錯誤：AZURE_OPENAI_ENDPOINT 環境變數未設定。請檢查您的 .env 檔案。")
	}
	if cfg.AzureOpenAIAPIKey == "" {
		log.Fatal("錯誤：AZURE_OPENAI_API_KEY 環境變數未設定。這是訪問 Azure OpenAI (包括 Sora) 的必要金鑰。")
	}
	if cfg.AzureOpenAISoraDeploymentName == "" {
		log.Fatal("錯誤：AZURE_OPENAI_SORA_DEPLOYMENT_NAME 環境變數未設定。請檢查您的 .env 檔案。")
	}
	if cfg.AzureOpenAISoraAPIVersion == "" {
		log.Fatal("錯誤：AZURE_OPENAI_SORA_API_VERSION 環境變數未設定。請檢查您的 .env 檔案。")
	}


	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":8081"
	}
	if cfg.RedisAddr == "" {
		cfg.RedisAddr = "127.0.0.1:6379"
	}
	// 處理 REDIS_DB 變數，預設為 1
	redisDBStr := os.Getenv("REDIS_DB")
	if redisDBStr != "" {
		db, err := strconv.Atoi(redisDBStr)
		if err == nil {
			cfg.RedisDB = db
		} else {
            log.Printf("警告: REDIS_DB 環境變數 '%s' 無法轉換為數字，將使用預設值 1。", redisDBStr)
            cfg.RedisDB = 1
        }
	} else {
        cfg.RedisDB = 1 // 如果未設定，預設為 1
    }
	
	// 載入 Sora 影片尺寸配置
	if w, err := strconv.Atoi(os.Getenv("SORA_DEFAULT_WIDTH")); err == nil && w > 0 {
		cfg.SoraDefaultWidth = w
	} else {
		cfg.SoraDefaultWidth = 1920 // 預設值
	}
	if h, err := strconv.Atoi(os.Getenv("SORA_DEFAULT_HEIGHT")); err == nil && h > 0 {
		cfg.SoraDefaultHeight = 1080 // 預設值
	}
	if s, err := strconv.Atoi(os.Getenv("SORA_DEFAULT_N_SECONDS")); err == nil && s > 0 {
		cfg.SoraDefaultNSeconds = s
	} else {
		cfg.SoraDefaultNSeconds = 10 // 預設值
	}
	
	cfg.TelegramWebhookURL = os.Getenv("TELEGRAM_WEBHOOK_BASE_URL") + cfg.TelegramWebhookPath

	if cfg.TelegramWebhookURL == "" {
		log.Fatal("錯誤：TELEGRAM_WEBHOOK_BASE_URL 環境變數未設定。請檢查您的 .env 檔案。")
	}

	log.Println("設定載入成功。")
	return cfg
}
EOF

echo "正在生成 models/models.go 檔案..."
cat > models/models.go << "EOF"
package models

// RoomConfig 僅包含聊天室ID和批准狀態，因為AI功能現在只專注於Sora影片生成
type RoomConfig struct {
	ChatID   int64  `json:"chat_id"`
	Approved bool `json:"approved"`
}

// Message 結構用於任何需要處理的文字訊息，例如命令參數，不再用於保存聊天歷史
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
EOF

# 移除 services/openai.go 檔案
echo "正在移除 services/openai.go 檔案 (不再需要通用AI聊天功能)..."
rm -f services/openai.go

echo "正在生成 services/redis.go 檔案..."
cat > services/redis.go << "EOF"
package services

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"github.com/redis/go-redis/v9"
	"telegram-go-bot-sora/models"
)

type RedisService struct {
	client *redis.Client
	ctx    context.Context
}

func NewRedisService(addr, password string, db int) *RedisService {
	rdb := redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: password,
		DB:       db,
	})

	ctx := context.Background()

	_, err := rdb.Ping(ctx).Result()
	if err != nil {
		log.Fatalf("無法連接到 Redis: %v", err)
	}

	log.Printf("成功連接到 Redis (DB: %d)。", db)
	return &RedisService{
		client: rdb,
		ctx:    ctx,
	}
}

func (s *RedisService) Close() error {
	return s.client.Close()
}

func (s *RedisService) SaveRoomConfig(config *models.RoomConfig) error {
	key := fmt.Sprintf("room_config:%d", config.ChatID)
	data, err := json.Marshal(config)
	if err != nil {
		return fmt.Errorf("序列化聊天室配置失敗: %w", err)
	}
	return s.client.Set(s.ctx, key, data, 0).Err()
}

func (s *RedisService) GetRoomConfig(chatID int64) (*models.RoomConfig, error) {
	key := fmt.Sprintf("room_config:%d", chatID)
	data, err := s.client.Get(s.ctx, key).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("從 Redis 獲取聊天室配置失敗: %w", err)
	}

	var config models.RoomConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("反序列化聊天室配置失敗: %w", err)
	}
	return &config, nil
}

func (s *RedisService) DeleteRoomConfig(chatID int64) error {
	key := fmt.Sprintf("room_config:%d", chatID)
	return s.client.Del(s.ctx, key).Err()
}

func (s *RedisService) GetAllRoomConfigKeys() ([]string, error) {
	iter := s.client.Scan(s.ctx, 0, "room_config:*", 0).Iterator()
	var keys []string
	for iter.Next(s.ctx) {
		keys = append(keys, iter.Val())
	}
	if err := iter.Err(); err != nil {
		return nil, fmt.Errorf("failed to scan room config keys: %w", err)
	}
	return keys, nil
}
EOF

echo "正在生成 services/sora.go 檔案..."
cat > services/sora.go << "EOF"
package services

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"strconv"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"telegram-go-bot-sora/config"
)

type SoraService struct {
	bot               *tgbotapi.BotAPI
	endpoint          string
	deploymentName    string
	apiVersion        string
	apiKey            string
	defaultWidth      int
	defaultHeight     int
	defaultNSeconds   int
}

func NewSoraService(cfg *config.Config, bot *tgbotapi.BotAPI) *SoraService {
	return &SoraService{
		bot:               bot,
		endpoint:          cfg.AzureOpenAIEndpoint,
		deploymentName:    cfg.AzureOpenAISoraDeploymentName,
		apiVersion:        cfg.AzureOpenAISoraAPIVersion,
		apiKey:            cfg.AzureOpenAIAPIKey,
		defaultWidth:      cfg.SoraDefaultWidth,
		defaultHeight:     cfg.SoraDefaultHeight,
		defaultNSeconds:   cfg.SoraDefaultNSeconds,
	}
}

func (s *SoraService) GenerateVideo(chatID int64, prompt string) (string, error) {
	log.Printf("SoraService: 準備生成影片。Prompt: \"%s\"", prompt)
	s.sendMessage(chatID, "開始生成影片... 🎬")

	createURL := fmt.Sprintf("%s/openai/v1/video/generations/jobs?api-version=%s", strings.TrimSuffix(s.endpoint, "/"), s.apiVersion)

	payload := map[string]interface{}{
		"model":      s.deploymentName,
		"prompt":     prompt,
		// 修正: 將整數值轉換為字串，以符合官方文件格式
		"width":      strconv.Itoa(s.defaultWidth),
		"height":     strconv.Itoa(s.defaultHeight),
		"n_seconds":  strconv.Itoa(s.defaultNSeconds),
		"n_variants": strconv.Itoa(1), // 預設生成一個變體，也轉為字串
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("SoraService: JSON 編碼失敗: %w", err)
	}

	req, err := http.NewRequest("POST", createURL, bytes.NewBuffer(body))
	if err != nil {
		return "", fmt.Errorf("SoraService: 建立影片生成請求失敗: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("api-key", s.apiKey)
	
	log.Printf("SoraService: 正在發送 curl 請求：\ncurl -X POST \"%s\" \\\n  -H \"Content-Type: application/json\" \\\n  -H \"Api-key: %s\" \\\n  -d '%s'",
		createURL, s.apiKey, string(body))

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("SoraService: 提交影片生成請求失敗: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := ioutil.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated {
		return "", fmt.Errorf("SoraService: 提交影片生成請求失敗，狀態碼: %d，回應內容: %s", resp.StatusCode, string(respBody))
	}

	var createResult map[string]interface{}
	if err := json.Unmarshal(respBody, &createResult); err != nil {
		return "", fmt.Errorf("SoraService: 解析生成請求回應失敗: %w", err)
	}

	jobID, ok := createResult["id"].(string)
	if !ok {
		return "", fmt.Errorf("SoraService: 生成請求回應中未找到 job ID")
	}
	log.Printf("SoraService: 影片生成任務已提交，Job ID: %s", jobID)
	s.sendMessage(chatID, "開始輪詢影片生成狀態... 🔄")

	var currentStatus string
	var statusResult map[string]interface{}
	for currentStatus != "succeeded" && currentStatus != "failed" && currentStatus != "cancelled" {
		time.Sleep(5 * time.Second)

		statusURL := fmt.Sprintf("%s/openai/v1/video/generations/jobs/%s?api-version=%s", strings.TrimSuffix(s.endpoint, "/"), jobID, s.apiVersion)
		statusReq, err := http.NewRequest("GET", statusURL, nil)
		if err != nil {
			return "", fmt.Errorf("SoraService: 建立狀態查詢請求失敗: %w", err)
		}
		statusReq.Header.Set("api-key", s.apiKey)

		statusResp, err := client.Do(statusReq)
		if err != nil {
			return "", fmt.Errorf("SoraService: 查詢狀態失敗: %w", err)
		}
		statusBody, _ := ioutil.ReadAll(statusResp.Body)
		statusResp.Body.Close()

		if statusResp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("SoraService: 查詢狀態請求失敗，狀態碼: %d，回應內容: %s", statusResp.StatusCode, string(statusBody))
		}

		if err := json.Unmarshal(statusBody, &statusResult); err != nil {
			return "", fmt.Errorf("SoraService: 解析狀態回應失敗: %w", err)
		}
		
		tempStatus, ok := statusResult["status"].(string)
		if !ok {
			return "", fmt.Errorf("SoraService: 狀態回應中未找到 'status' 字段")
		}
		
		if currentStatus != tempStatus {
			currentStatus = tempStatus
			log.Printf("SoraService: Job 狀態: %s", currentStatus)
			s.sendMessage(chatID, fmt.Sprintf("Job 狀態: %s", currentStatus))
		}
	}

	if currentStatus != "succeeded" {
		s.sendMessage(chatID, fmt.Sprintf("影片生成任務未成功。最終狀態: %s ❌", currentStatus))
		return "", fmt.Errorf("SoraService: 影片生成任務未成功。最終狀態: %s", currentStatus)
	}

	s.sendMessage(chatID, "✅ 影片生成成功。")

	generations, ok := statusResult["generations"].([]interface{})
	if !ok || len(generations) == 0 {
		return "", fmt.Errorf("SoraService: 影片生成成功，但未找到影片內容。")
	}

	firstGeneration, ok := generations[0].(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("SoraService: 無法解析生成結果。")
	}

	generationID, ok := firstGeneration["id"].(string)
	if !ok {
		return "", fmt.Errorf("SoraService: 未找到 generation ID。")
	}

	videoURL := fmt.Sprintf("%s/openai/v1/video/generations/%s/content/video?api-version=%s", strings.TrimSuffix(s.endpoint, "/"), generationID, s.apiVersion)
	log.Printf("SoraService: 正在下載影片: %s", videoURL)
	s.sendMessage(chatID, "正在下載影片... 📥")

	videoReq, err := http.NewRequest("GET", videoURL, nil)
	if err != nil {
		return "", fmt.Errorf("SoraService: 建立影片下載請求失敗: %w", err)
	}
	videoReq.Header.Set("api-key", s.apiKey)

	finalVideoResp, err := client.Do(videoReq)
	if err != nil {
		return "", fmt.Errorf("SoraService: 下載影片失敗: %w", err)
	}
	defer finalVideoResp.Body.Close()

	if finalVideoResp.StatusCode != http.StatusOK {
		videoErrorBody, _ := ioutil.ReadAll(finalVideoResp.Body)
		return "", fmt.Errorf("SoraService: 下載影片失敗，狀態碼: %d，回應: %s", finalVideoResp.StatusCode, string(videoErrorBody))
	}

	outputFilename := fmt.Sprintf("sora_output_%d.mp4", time.Now().Unix())
	outputPath := filepath.Join("tmp", outputFilename)
	file, err := os.Create(outputPath)
	if err != nil {
		return "", fmt.Errorf("SoraService: 建立檔案 %s 失敗: %w", outputPath, err)
	}
	defer file.Close()

	_, err = io.Copy(file, finalVideoResp.Body)
	if err != nil {
		return "", fmt.Errorf("SoraService: 寫入影片檔案 %s 失敗: %w", outputPath, err)
	}
	log.Printf("SoraService: 生成的影片已儲存為 \"%s\"", outputPath)
	s.sendMessage(chatID, fmt.Sprintf("影片已下載到伺服器: `%s`", outputFilename))

	return outputPath, nil
}

func (s *SoraService) sendMessage(chatID int64, text string) {
	msg := tgbotapi.NewMessage(chatID, text)
	msg.ParseMode = tgbotapi.ModeMarkdown
	_, err := s.bot.Send(msg)
	if err != nil {
		log.Printf("錯誤：SoraService 無法發送訊息到聊天室 %d: %v", chatID, err)
	}
}
EOF

echo "正在生成 handlers/telegram.go 檔案..."
cat > handlers/telegram.go << "EOF"
package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"os"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"telegram-go-bot-sora/config"
	"telegram-go-bot-sora/models"
	"telegram-go-bot-sora/services"
)

type TelegramWebhookHandler struct {
	bot        *tgbotapi.BotAPI
	cfg        *config.Config
	redisSvc   *services.RedisService
	soraSvc    *services.SoraService
}

func NewTelegramWebhookHandler(
	bot *tgbotapi.BotAPI,
	cfg *config.Config,
	redisSvc *services.RedisService,
	soraSvc *services.SoraService,
) *TelegramWebhookHandler {
	return &TelegramWebhookHandler{
		bot:        bot,
		cfg:        cfg,
		redisSvc:   redisSvc,
		soraSvc:    soraSvc,
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

	if strings.HasPrefix(messageText, "/startvideo") {
		h.handleStartVideoCommand(chatID, userName)
		w.WriteHeader(http.StatusOK)
		return
	}

	if strings.HasPrefix(messageText, "/video ") {
		prompt := strings.TrimPrefix(messageText, "/video ")
		prompt = strings.TrimSpace(prompt)
		h.handleVideoCommand(chatID, prompt)
		w.WriteHeader(http.StatusOK)
		return
	}

	roomConfig, err := h.redisSvc.GetRoomConfig(chatID)
	if err != nil {
		log.Printf("錯誤：無法獲取聊天室 %d 的配置: %v", chatID, err)
		h.sendMessage(chatID, "發生內部錯誤，請稍後再試。")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	if roomConfig == nil || !roomConfig.Approved {
		log.Printf("聊天室 %d 未獲批，提示用戶。", chatID)
		response := "此聊天室的影片生成功能尚未啟用。請聯繫管理員審批。\n" +
			"如果您是管理員，請確認該聊天室的配置已在 Redis 中設置為 `approved: true`。" +
            "請發送 `/startvideo` 以初始化本聊天室。"
		h.sendMessage(chatID, response)
		w.WriteHeader(http.StatusOK)
		return
	} else {
		log.Printf("聊天室 %d 已獲批，但收到非 /startvideo 或 /video 命令。", chatID)
		h.sendMessage(chatID, "我是一個影片生成機器人！請使用 `/video 您的影片描述` 來生成影片。")
		w.WriteHeader(http.StatusOK)
		return
	}
}

func (h *TelegramWebhookHandler) handleStartVideoCommand(chatID int64, userName string) {
	log.Printf("處理 /startvideo 命令 (ChatID: %d, User: %s)", chatID, userName)
	roomConfig, err := h.redisSvc.GetRoomConfig(chatID)
	if err != nil {
		log.Printf("處理 /startvideo 命令時無法獲取聊天室 %d 的配置: %v", chatID, err)
		h.sendMessage(chatID, "處理您的請求時發生內部錯誤。")
		return
	}

	if roomConfig == nil {
		newConfig := &models.RoomConfig{
			ChatID:    chatID,
			Approved:  false,
		}
		if err := h.redisSvc.SaveRoomConfig(newConfig); err != nil {
			log.Printf("保存新的聊天室 %d 配置失敗: %v", chatID, err)
			h.sendMessage(chatID, "無法初始化聊天室配置，請聯繫管理員。")
			return
		}
		log.Printf("新聊天室 %d (使用者: %s) 已註冊，等待管理員審批以啟用影片生成功能。", chatID, userName)
		response := fmt.Sprintf("您好 %s！此聊天室 ID 為 `%d`。\n", userName, chatID) +
			"請管理員透過後台 API 審批，即可啟用影片生成功能。"
		h.sendMessage(chatID, response)
	} else if !roomConfig.Approved {
		log.Printf("聊天室 %d 尚未獲批 (處理 /startvideo 命令)。", chatID)
		response := fmt.Sprintf("此聊天室 ID 為 `%d`。影片生成功能尚未啟用。\n", chatID) +
			"請等待管理員審批。謝謝！"
		h.sendMessage(chatID, response)
	} else {
		log.Printf("聊天室 %d 已獲批 (處理 /startvideo 命令)。", chatID)
		response := fmt.Sprintf("您好 %s！此聊天室 ID 為 `%d`。\n", userName, chatID) +
			"影片生成功能已啟用！請使用 `/video 您的影片描述` 來生成影片。"
		h.sendMessage(chatID, response)
	}
}

func (h *TelegramWebhookHandler) handleVideoCommand(chatID int64, prompt string) {
	log.Printf("處理 /video 命令 (ChatID: %d, Prompt: \"%s\")", chatID, prompt)

	roomConfig, err := h.redisSvc.GetRoomConfig(chatID)
	if err != nil {
		log.Printf("處理 /video 命令時無法獲取聊天室 %d 的配置: %v", chatID, err)
		h.sendMessage(chatID, "處理您的請求時發生內部錯誤。")
		return
	}

	if roomConfig == nil || !roomConfig.Approved {
		log.Printf("聊天室 %d 未獲批，拒絕影片生成請求。", chatID)
		response := "此聊天室的影片生成功能尚未啟用。請聯繫管理員審批。\n" +
			"如果您是管理員，請確認該聊天室的配置已在 Redis 中設置為 `approved: true`。" +
            "請發送 `/startvideo` 以初始化本聊天室。"
		h.sendMessage(chatID, response)
		return
	}

	if prompt == "" {
		h.sendMessage(chatID, "請提供影片生成的文字描述，例如：`/video 一隻可愛的貓咪在彈鋼琴`")
		return
	}

	processingMsg, err := h.bot.Send(tgbotapi.NewMessage(chatID, "正在生成影片，這可能需要幾分鐘，請耐心等待... ⏳"))
	if err != nil {
		log.Printf("發送處理訊息失敗: %v", err)
	}

	videoFilePath, err := h.soraSvc.GenerateVideo(chatID, prompt)
	if err != nil {
		log.Printf("Sora 影片生成失敗 (ChatID: %d): %v", chatID, err)
		h.sendMessage(chatID, fmt.Sprintf("影片生成失敗: %v 請檢查後台日誌或重試。", err))
	} else {
		log.Printf("Sora 影片生成成功，檔案路徑: %s", videoFilePath)
		videoFile := tgbotapi.FilePath(videoFilePath)
		msg := tgbotapi.NewVideo(chatID, videoFile)
		msg.Caption = fmt.Sprintf("✨ 您的影片已生成！\n\n描述: \"%s\"", prompt)
		
		_, err := h.bot.Send(msg)
		if err != nil {
			log.Printf("發送影片到 Telegram 失敗 (ChatID: %d): %v", err)
			h.sendMessage(chatID, "影片生成成功，但發送到 Telegram 失敗。請稍後再試。")
		} else {
			log.Printf("成功發送影片到 Telegram (ChatID: %d)", chatID)
		}

		if err := os.Remove(videoFilePath); err != nil {
			log.Printf("刪除臨時影片檔案失敗 (%s): %v", videoFilePath, err)
		} else {
			log.Printf("成功刪除臨時影片檔案: %s", videoFilePath)
		}
	}

	if processingMsg.MessageID != 0 {
		deleteMsg := tgbotapi.NewDeleteMessage(chatID, processingMsg.MessageID)
		_, err := h.bot.Request(deleteMsg)
		if err != nil {
			log.Printf("刪除處理訊息失敗: %v", err)
		}
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
EOF

echo "正在生成 main.go 檔案..."
cat > main.go << "EOF"
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"telegram-go-bot-sora/config"
	"telegram-go-bot-sora/handlers"
	"telegram-go-bot-sora/models"
	"telegram-go-bot-sora/services"
)

func main() {
	err := godotenv.Load()
	if err != nil {
		log.Printf("Warning: 無法載入 .env 檔案，可能使用系統環境變數: %v", err)
	}

	cfg := config.LoadConfig()

	bot, err := tgbotapi.NewBotAPI(cfg.TelegramBotToken)
	if err != nil {
		log.Fatalf("無法建立 Telegram Bot API: %v", err)
	}
	bot.Debug = false
	log.Printf("已授權帳戶: @%s", bot.Self.UserName)

	webhookConfig, err := tgbotapi.NewWebhook(cfg.TelegramWebhookURL)
	if err != nil {
		log.Fatalf("無法建立 Webhook 配置: %v", err)
	}
	_, err = bot.Request(webhookConfig)
	if err != nil {
		log.Fatalf("無法設定 Telegram Webhook: %v", err)
	}
	log.Printf("Telegram Webhook 已設定為: %s", webhookConfig.URL)

	redisSvc := services.NewRedisService(cfg.RedisAddr, cfg.RedisPassword, cfg.RedisDB)
	defer func() {
		if err := redisSvc.Close(); err != nil {
			log.Printf("關閉 Redis 連接時發生錯誤: %v", err)
		}
	}()

	soraSvc := services.NewSoraService(cfg, bot)

	tgHandler := handlers.NewTelegramWebhookHandler(bot, cfg, redisSvc, soraSvc)

	mux := http.NewServeMux()

	mux.HandleFunc(cfg.TelegramWebhookPath, tgHandler.HandleUpdate)
	log.Printf("Telegram Webhook 監聽在 %s", cfg.TelegramWebhookPath)

	log.Println("警告：管理員 API 目前沒有任何身份驗證機制。在生產環境中，**強烈建議您為這些接口添加身份驗證！**")

	mux.HandleFunc("/admin/rooms", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "不允許的方法 (Method Not Allowed)", http.StatusMethodNotAllowed)
			return
		}
		
		keys, err := redisSvc.GetAllRoomConfigKeys()
		if err != nil {
			log.Printf("獲取所有聊天室配置鍵失敗: %v", err)
			http.Error(w, "內部伺服器錯誤 (Internal Server Error)", http.StatusInternalServerError)
			return
		}

		var allConfigs []models.RoomConfig
		for _, key := range keys {
			var chatID int64
			fmt.Sscanf(key, "room_config:%d", &chatID)
			
			config, err := redisSvc.GetRoomConfig(chatID)
			if err != nil {
				log.Printf("獲取聊天室 %d 配置失敗: %v", chatID, err)
				continue
			}
			if config != nil {
				allConfigs = append(allConfigs, *config)
			}
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(allConfigs); err != nil {
			log.Printf("編碼聊天室配置失敗: %v", err)
			http.Error(w, "內部伺服器錯誤 (Internal Server Error)", http.StatusInternalServerError)
		}
	})

	mux.HandleFunc("/admin/set_room_config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "不允許的方法 (Method Not Allowed)", http.StatusMethodNotAllowed)
			return
		}

		var reqConfig models.RoomConfig
		if err := json.NewDecoder(r.Body).Decode(&reqConfig); err != nil {
			http.Error(w, "無效的請求主體 (Invalid request body)", http.StatusBadRequest)
			return
		}

		if err := redisSvc.SaveRoomConfig(&reqConfig); err != nil {
			log.Printf("無法保存聊天室配置: %v", err)
			http.Error(w, "內部伺服器錯誤 (Internal Server Error)", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "聊天室 %d 配置已成功更新。", reqConfig.ChatID)
		log.Printf("聊天室 %d 配置已成功更新。", reqConfig.ChatID)
	})

	mux.HandleFunc("/admin/delete_room_config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "不允許的方法 (Method Not Allowed)", http.StatusMethodNotAllowed)
			return
		}

		var req struct {
			ChatID int64 `json:"chat_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "無效的請求主體 (Invalid request body)", http.StatusBadRequest)
			return
		}

		if err := redisSvc.DeleteRoomConfig(req.ChatID); err != nil {
			log.Printf("無法刪除聊天室 %d 配置: %v", req.ChatID, err)
			http.Error(w, "內部伺服器錯誤 (Internal Server Error)", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "聊天室 %d 配置已成功刪除。", req.ChatID)
		log.Printf("聊天室 %d 配置已成功刪除。", req.ChatID)
	})

	srv := &http.Server{
		Addr:    cfg.ListenAddr,
		Handler: mux,
	}

	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("監聽失敗: %v", err)
		}
	}()
	log.Printf("HTTP 伺服器正在 %s 上監聽...", cfg.ListenAddr)

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("收到關閉信號，正在關閉伺服器...")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("伺服器強制關閉: %v", err)
	}
	log.Println("伺服器已優雅關閉。")
}
EOF

echo "專案文件已成功生成在 ./$PROJECT_DIR/ 目錄中。"
echo ""
echo "======================================================================"
echo "                   管理員 API 說明 (⚠️ **重要提示：無身份驗證！**)"
echo "======================================================================"
echo "這些管理員 API 接口目前不包含任何身份驗證機制。**在任何生產環境中部署前，務必為這些接口添加強大的身份驗證（例如 API Key、OAuth2 等）以防止未經授權的訪問！**"
echo ""
echo "此機器人專用的 Redis 資料庫為 **DB 1**，請確保您的 Redis 伺服器已正確配置。"
echo ""
echo "### 1. 獲取所有已配置的聊天室資訊"
echo "   \`GET http://localhost:8081/admin/rooms\`"
echo "   此接口將返回所有儲存在 Redis 中聊天室的詳細配置。返回的配置只包含 \`chat_id\` 和 \`approved\` 狀態。"
echo ""
echo "   **範例 cURL 請求**:"
echo "   \`\`\`bash"
echo "   curl -X GET http://localhost:8081/admin/rooms"
echo "   \`\`\`"
echo ""
echo "### 2. 設定或更新聊天室配置 (啟用/禁用影片生成功能)"
echo "   \`POST http://localhost:8081/admin/set_room_config\`"
echo "   使用此接口設定或修改特定 Telegram 聊天室的影片生成功能啟用狀態。"
echo ""
echo "   **請求主體 (JSON)**:"
echo "   \`\`\`json"
echo "   {"
echo "     \"chat_id\": YOUR_TELEGRAM_CHAT_ID,"
echo "     \"approved\": true"
echo "   }"
echo "   \`\`\`"
echo "   * \`chat_id\`: 必填，Telegram 聊天室的唯一識別符 (例如：私聊為用戶ID，群組為負數ID)。"
echo "   * \`approved\`: 必填，布林值。設為 \`true\` 啟用該聊天室的影片生成功能，\`false\` 禁用。"
echo "   * **注意**：不再需要 \`api_key\` 和 \`model_name\`，因為所有 Sora 請求將使用 .env 中統一配置的 `AZURE_OPENAI_API_KEY`。"
echo ""
echo "   **範例 cURL 請求**:"
echo "   \`\`\`bash"
echo "   curl -X POST -H \"Content-Type: application/json\" \\"
echo "        -d '{ \"chat_id\": -4944411011, \"approved\": true }' \\"
echo "        http://localhost:8081/admin/set_room_config"
echo "   \`\`\`"
echo ""
echo "### 3. 刪除聊天室配置"
echo "   \`POST http://localhost:8081/admin/delete_room_config\`"
echo "   此接口將從 Redis 中完全移除指定聊天室的配置。請注意，這將禁用該聊天室的所有影片生成功能。"
echo ""
echo "   **請求主體 (JSON)**:"
echo "   \`\`\`json"
echo "   {"
echo "     \"chat_id\": YOUR_TELEGRAM_CHAT_ID"
echo "   }"
echo "   \`\`\`"
echo ""
echo "   **範例 cURL 請求**:"
echo "   \`\`\`bash"
echo "   curl -X POST -H \"Content-Type: application/json\" \\"
echo "        -d '{ \"chat_id\": -4944411011 }' \\"
echo "        http://localhost:8081/admin/delete_room_config"
echo "   \`\`\`"
echo ""
echo "### 聊天室啟用流程概述 (專為影片生成功能設計)"
echo "1.  **用戶發起**: 用戶在 Telegram 中向您的機器人發送 \`/startvideo\` 命令。"
echo "2.  **自動註冊**: 機器人會自動將該聊天室的 ID 記錄到 Redis (DB 1)，初始狀態為 \`approved: false\`，表示影片生成功能未啟用。"
echo "3.  **管理員審批**: 管理員需要手動透過上述 \`/admin/set_room_config\` API，將該聊天室的 \`approved\` 字段設置為 \`true\`。"
echo "4.  **影片生成功能啟用**: 聊天室一旦被審批完成，用戶即可開始使用 \`/video\` 命令生成影片。"
echo ""
exit 0
