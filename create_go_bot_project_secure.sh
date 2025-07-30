#!/bin/bash
set -e

PROJECT_DIR="telegram-go-bot-host"
GO_MODULE_NAME="telegram-go-bot-host"

echo "正在創建專案目錄: $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR/config" \
         "$PROJECT_DIR/handlers" \
         "$PROJECT_DIR/models" \
         "$PROJECT_DIR/services"

cd "$PROJECT_DIR" || exit

echo "正在生成 go.mod 檔案..."
cat > go.mod << EOF
module telegram-go-bot-host

go 1.23

require (
        github.com/go-telegram-bot-api/telegram-bot-api/v5 v5.5.1
        github.com/sashabaranov/go-openai v1.40.5
        github.com/pkoukk/tiktoken-go v0.1.6
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
TELEGRAM_BOT_TOKEN="8343:AAGntYW9Tf4og"
AZURE_OPENAI_ENDPOINT="https://admin.cognitiveservices.azure.com/"
AZURE_OPENAI_API_VERSION="2024-12-01-preview"
DEFAULT_OPENAI_DEPLOYMENT_NAME="gpt-4.1-nano"
AZURE_OPENAI_API_KEY="J3w3AAAAACOGakAh"
LISTEN_ADDR=":8080"
REDIS_ADDR="localhost:6379"
REDIS_PASSWORD=""
REDIS_DB=0
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
        AzureOpenAIAPIVersion       string
        DefaultOpenAIDeploymentName string
        AzureOpenAIAPIKey           string
        ReservedForResponseTokens   int
        ModelTokenLimits            map[string]int
        MaxContextMessages          int
        TokenWarningThreshold       float64
}

func LoadConfig() *Config {
        cfg := &Config{
                TelegramBotToken:            os.Getenv("TELEGRAM_BOT_TOKEN"),
                TelegramWebhookPath:         "/telegram_webhook/" + os.Getenv("TELEGRAM_BOT_TOKEN"),
                ListenAddr:                  os.Getenv("LISTEN_ADDR"),
                RedisAddr:                   os.Getenv("REDIS_ADDR"),
                RedisPassword:               os.Getenv("REDIS_PASSWORD"),
                AzureOpenAIEndpoint:         os.Getenv("AZURE_OPENAI_ENDPOINT"),
                AzureOpenAIAPIVersion:       os.Getenv("AZURE_OPENAI_APIVersion"),
                DefaultOpenAIDeploymentName: os.Getenv("DEFAULT_OPENAI_DEPLOYMENT_NAME"),
                AzureOpenAIAPIKey:           os.Getenv("AZURE_OPENAI_API_KEY"),
                ReservedForResponseTokens:   500,
                MaxContextMessages:          10,
                TokenWarningThreshold:       0.9,
                ModelTokenLimits: map[string]int{
                        "gpt-35-turbo":            4096,
                        "gpt-35-turbo-16k":        16384,
                        "gpt-4":                   8192,
                        "gpt-4-32k":               32768,
                        "gpt-4o":                  128000,
                        "gpt-4o-mini":             128000,
                        "gpt-4.1-nano-deployment": 1000000,
                        "gpt-4.1-nano": 1000000,
                },
        }

        if cfg.TelegramBotToken == "" {
                log.Fatal("錯誤：TELEGRAM_BOT_TOKEN 環境變數未設定。請檢查您的 .env 檔案。")
        }
        if cfg.AzureOpenAIEndpoint == "" {
                log.Fatal("錯誤：AZURE_OPENAI_ENDPOINT 環境變數未設定。請檢查您的 .env 檔案。")
        }
        if cfg.DefaultOpenAIDeploymentName == "" {
                log.Fatal("錯誤：DEFAULT_OPENAI_DEPLOYMENT_NAME 環境變數未設定。請檢查您的 .env 檔案。")
        }
        if cfg.AzureOpenAIAPIKey == "" {
                log.Fatal("錯誤：AZURE_OPENAI_API_KEY 環境變數未設定。請檢查您的 .env 檔案。")
        }

        if cfg.ListenAddr == "" {
                cfg.ListenAddr = ":8080"
        }
        if cfg.RedisAddr == "" {
                cfg.RedisAddr = "127.0.0.1:6379"
        }
        if cfg.AzureOpenAIAPIVersion == "" {
                cfg.AzureOpenAIAPIVersion = "2024-02-15-preview"
        }

        redisDBStr := os.Getenv("REDIS_DB")
        if redisDBStr != "" {
                db, err := strconv.Atoi(redisDBStr)
                if err == nil {
                        cfg.RedisDB = db
                }
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

type RoomConfig struct {
        ChatID   int64  `json:"chat_id"`
        APIKey   string `json:"api_key"`
        Approved bool `json:"approved"`
        ModelName string `json:"model_name"`
}

type Message struct {
        Role    string `json:"role"`
        Content string `json:"content"`
}
EOF

echo "正在生成 services/redis.go 檔案..."
cat > services/redis.go << "EOF"
package services

import (
        "context"
        "encoding/json"
        "fmt"
        "log"
        "time"

        "github.com/redis/go-redis/v9"
        "telegram-go-bot-host/models"
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

        log.Println("成功連接到 Redis。")
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

func (s *RedisService) SaveMessages(chatID int64, messages []models.Message) error {
        key := fmt.Sprintf("chat_history:%d", chatID)
        data, err := json.Marshal(messages)
        if err != nil {
                return fmt.Errorf("序列化聊天歷史失敗: %w", err)
        }
        return s.client.Set(s.ctx, key, data, 24*time.Hour).Err()
}

func (s *RedisService) GetMessages(chatID int64) ([]models.Message, error) {
        key := fmt.Sprintf("chat_history:%d", chatID)
        data, err := s.client.Get(s.ctx, key).Bytes()
        if err == redis.Nil {
                return []models.Message{}, nil
        }
        if err != nil {
                return nil, fmt.Errorf("從 Redis 獲取聊天歷史失敗: %w", err)
        }

        var messages []models.Message
        if err := json.Unmarshal(data, &messages); err != nil {
                return nil, fmt.Errorf("反序列化聊天歷史失敗: %w", err)
        }
        return messages, nil
}

func (s *RedisService) ClearMessages(chatID int64) error {
        key := fmt.Sprintf("chat_history:%d", chatID)
        return s.client.Del(s.ctx, key).Err()
}
EOF

echo "正在生成 services/openai.go 檔案..."
cat > services/openai.go << "EOF"
package services

import (
        "bytes"
        "encoding/json"
        "fmt"
        "io"
        "log"
        "net/http"
        "net/http/httputil"
        "strings"

        tokenizer "github.com/pkoukk/tiktoken-go"
        "telegram-go-bot-host/config"
        "telegram-go-bot-host/models"
)

type OpenAIService struct {
        endpoint          string
        apiVersion        string
        defaultDeployment string
        modelTokenLimits  map[string]int
        reservedTokens    int
        apiKey            string
}

func NewOpenAIService(cfg *config.Config) *OpenAIService {
        return &OpenAIService{
                endpoint:          cfg.AzureOpenAIEndpoint,
                apiVersion:        cfg.AzureOpenAIAPIVersion,
                defaultDeployment: cfg.DefaultOpenAIDeploymentName,
                modelTokenLimits:  cfg.ModelTokenLimits,
                reservedTokens:    cfg.ReservedForResponseTokens,
                apiKey:            cfg.AzureOpenAIAPIKey,
        }
}

func (s *OpenAIService) GetModelMaxTokens(modelName string) int {
        if limit, ok := s.modelTokenLimits[modelName]; ok {
                return limit
        }
        return 4096
}

func (s *OpenAIService) CountTokens(modelName string, messages []models.Message) (int, error) {
        var encodingName string
        switch modelName {
        case "gpt-35-turbo", "gpt-4", "gpt-4o-mini":
                encodingName = "cl100k_base"
        case "gpt-4o":
                encodingName = "o200k_base"
        default:
                encodingName = "cl100k_base"
        }

        enc, err := tokenizer.GetEncoding(encodingName)
        if err != nil {
                log.Printf("Warning: Could not get tiktoken encoding for model %s (encoding name: %s). Using cl100k_base fallback. Error: %v", modelName, encodingName, err)
                enc, err = tokenizer.GetEncoding("cl100k_base")
                if err != nil {
                        return 0, fmt.Errorf("無法獲取 cl100k_base 編碼: %w", err)
                }
        }

        totalTokens := 0
        emptySpecial := []string{}
        for _, msg := range messages {
                totalTokens += len(enc.Encode(msg.Role, emptySpecial, emptySpecial))
                totalTokens += len(enc.Encode(msg.Content, emptySpecial, emptySpecial))
        }
        totalTokens += 3
        return totalTokens, nil
}

func (s *OpenAIService) TrimMessages(modelName string, messages []models.Message) ([]models.Message, int) {
        maxTokens := s.GetModelMaxTokens(modelName) - s.reservedTokens
        if maxTokens <= 0 {
                return []models.Message{}, 0
        }

        currentTokens, err := s.CountTokens(modelName, messages)
        if err != nil {
                log.Printf("Error counting tokens for trimming: %v", err)
                return messages, currentTokens
        }

        if currentTokens <= maxTokens {
                return messages, currentTokens
        }

        log.Printf("Messages (tokens: %d) exceed limit (%d) for model %s. Trimming...", currentTokens, maxTokens, modelName)

        trimmedMessages := make([]models.Message, 0, len(messages))
        systemMessageCount := 0

        for _, msg := range messages {
                if msg.Role == "system" {
                        trimmedMessages = append(trimmedMessages, msg)
                        systemMessageCount++
                }
        }

        for i := len(messages) - 1; i >= systemMessageCount; i-- {
                tempMessages := append(trimmedMessages, messages[i])
                tokens, err := s.CountTokens(modelName, tempMessages)
                if err != nil {
                        log.Printf("Error counting tokens during trimming loop: %v", err)
                        break
                }
                if tokens > maxTokens {
                        break
                }
                trimmedMessages = append([]models.Message{messages[i]}, trimmedMessages...)
        }

        finalTokens, _ := s.CountTokens(modelName, trimmedMessages);
        log.Printf("Trimmed messages down to %d tokens.", finalTokens)
        return trimmedMessages, finalTokens
}

func (s *OpenAIService) GetChatCompletion(apiKey, deploymentName string, messages []models.Message) (string, error) {
        if apiKey == "" {
                apiKey = s.apiKey
        }

        url := fmt.Sprintf("%sopenai/deployments/%s/chat/completions?api-version=%s", s.endpoint, deploymentName, s.apiVersion)

        reqMessages := make([]map[string]string, len(messages))
        for i, msg := range messages {
                reqMessages[i] = map[string]string{
                        "role":    msg.Role,
                        "content": msg.Content,
                }
        }

        // 新增：印出 services/openai.go 收到並即將丟給 Azure OpenAI 的文字
        log.Printf("--- OpenAI Service Received Messages ---")
        for i, msg := range reqMessages {
                log.Printf("Message %d: Role: %s, Content: \"%s\"", i+1, msg["role"], msg["content"])
        }
        log.Printf("--- End OpenAI Service Received Messages ---")


        payload := map[string]interface{}{
                "messages": reqMessages,
                "max_tokens":        800,
                "temperature":       1.0,
                "top_p":             1.0,
                "frequency_penalty": 0.0,
                "presence_penalty":  0.0,
        }

        jsonData, err := json.Marshal(payload)
        if err != nil {
                return "", fmt.Errorf("JSON 編碼錯誤: %w", err)
        }

        req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
        if err != nil {
                return "", fmt.Errorf("建立請求失敗: %w", err)
        }
        req.Header.Set("Content-Type", "application/json")
        req.Header.Set("api-key", apiKey)

        // 印出丟給 Azure OpenAI API 的內容
        requestDump, err := httputil.DumpRequestOut(req, true)
        if err != nil {
                log.Printf("Error dumping request: %v", err)
        } else {
                dumpString := string(requestDump)
                apiKeyHeader := "Api-Key: " + apiKey
                dumpString = strings.ReplaceAll(dumpString, apiKeyHeader, "Api-Key: [REDACTED]")
                log.Printf("--- OpenAI Request Start ---\n%s\n--- OpenAI Request End ---", dumpString)
        }

        client := &http.Client{}
        resp, err := client.Do(req)
        if err != nil {
                return "", fmt.Errorf("請求失敗: %w", err)
        }
        defer resp.Body.Close()

        // 印出回應的內容
        responseDump, err := httputil.DumpResponse(resp, true)
        if err != nil {
                log.Printf("Error dumping response: %v", err)
        } else {
                log.Printf("--- OpenAI Response Start (Status: %s) ---\n%s\n--- OpenAI Response End ---", resp.Status, string(responseDump))
        }

        body, err := io.ReadAll(resp.Body)
        if err != nil {
                return "", fmt.Errorf("讀取回應失敗: %w", err)
        }
        resp.Body = io.NopCloser(bytes.NewBuffer(body))

        var result struct {
                Choices []struct {
                        Message struct {
                                Content string `json:"content"`
                        } `json:"message"`
                } `json:"choices"`
        }

        if err := json.Unmarshal(body, &result); err != nil {
                log.Printf("回應解析錯誤: %v", err)
                log.Printf("原始回應: %s", string(body))
                return "", fmt.Errorf("回應解析錯誤: %w", err)
        }

        if len(result.Choices) > 0 {
                log.Printf("OpenAI 回應內容: \"%s\"", result.Choices[0].Message.Content)
                return result.Choices[0].Message.Content, nil
        }

        log.Printf("回應中沒有 choices")
        log.Printf("原始回應: %s", string(body))
        return "", fmt.Errorf("未從 OpenAI 收到任何回應")
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

	shouldProcessAI := false

	// 優先處理 /get 命令，無論是否提及機器人
	if strings.HasPrefix(messageText, "/get ") {
		messageText = strings.TrimPrefix(messageText, "/get ")
		messageText = strings.TrimSpace(messageText) // 再次修剪以防多餘空格
		shouldProcessAI = true
		log.Printf("已檢測到 '/get ' 命令。處理後訊息: \"%s\"", messageText)
	} else if update.Message.Chat.IsGroup() || update.Message.Chat.IsSuperGroup() {
		// 如果不是 /get 命令，則檢查群組訊息中的機器人提及或回覆
		botMentioned := false
		if update.Message.Entities != nil { 
			for _, entity := range update.Message.Entities { 
				if entity.Type == "mention" && update.Message.Text[entity.Offset:entity.Offset+entity.Length] == "@"+h.bot.Self.UserName {
					botMentioned = true
					break
				}
			}
		}
		if !botMentioned && update.Message.ReplyToMessage != nil && update.Message.ReplyToMessage.From.ID == h.bot.Self.ID {
			botMentioned = true
		}

		if botMentioned {
			messageText = strings.ReplaceAll(messageText, "@"+h.bot.Self.UserName, "")
			messageText = strings.TrimSpace(messageText)
			shouldProcessAI = true
			log.Printf("群組訊息已處理提及。ChatID: %d, 處理後訊息: \"%s\"", chatID, messageText)
		} else {
			log.Printf("群組訊息中未提及機器人且非回覆，忽略。ChatID: %d", chatID)
			w.WriteHeader(http.StatusOK)
			return
		}
	} else {
		// 私聊訊息，直接處理為 AI 請求
		shouldProcessAI = true
		log.Printf("私聊訊息，直接處理為 AI 請求。ChatID: %d, 訊息: \"%s\"", chatID, messageText)
	}


	if !shouldProcessAI {
		// 理論上這段程式碼不會執行，因為上面的邏輯已經覆蓋了所有情況
		// 如果執行到這裡，說明有未預期的情況發生，為安全起見，直接返回
		w.WriteHeader(http.StatusOK)
		return
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
		response := "此聊天室尚未啟用 AI 功能，請聯繫管理員審批並配置 OpenAI API 金鑰。\n" +
			"如果您是管理員，請確認該聊天室的配置已在 Redis 中設置為 `approved: true` 並填寫 `api_key` 和 `model_name`。"
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
			APIKey:    "",
			ModelName: h.cfg.DefaultOpenAIDeploymentName,
		}
		if err := h.redisSvc.SaveRoomConfig(newConfig); err != nil {
			log.Printf("保存新的聊天室 %d 配置失敗: %v", chatID, err)
			h.sendMessage(chatID, "無法初始化聊天室配置，請聯繫管理員。")
			return
		}
		log.Printf("新聊天室 %d (使用者: %s) 已註冊，等待管理員審批。", chatID, userName)
		response := fmt.Sprintf("您好 %s！此聊天室 ID 為 `%d`。\n", userName, chatID) +
			"請管理員透過後台 API 審批並為本聊天室配置 OpenAI API 金鑰和模型名稱，即可啟用 AI 功能。"
		h.sendMessage(chatID, response)
	} else if !roomConfig.Approved {
		log.Printf("聊天室 %d 尚未獲批 (處理 /start 命令)。", chatID)
		response := fmt.Sprintf("此聊天室 ID 為 `%d`。AI 功能尚未啟用。\n", chatID) +
			"請等待管理員審批並配置 API 金鑰。謝謝！"
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
        "telegram-go-bot-host/config"
        "telegram-go-bot-host/handlers"
        "telegram-go-bot-host/models"
        "telegram-go-bot-host/services"
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

        openaiSvc := services.NewOpenAIService(cfg)

        tgHandler := handlers.NewTelegramWebhookHandler(bot, cfg, redisSvc, openaiSvc)

        mux := http.NewServeMux()

        mux.HandleFunc(cfg.TelegramWebhookPath, tgHandler.HandleUpdate)
        log.Printf("Telegram Webhook 監聽在 %s", cfg.TelegramWebhookPath)

        log.Println("警告: 管理員 API (Admin API) 目前沒有任何身份驗證。請勿將其公開或在生產環境中使用前新增身份驗證！")

        mux.HandleFunc("/admin/rooms", func(w http.ResponseWriter, r *http.Request) {
                if r.Method != http.MethodGet {
                        http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
                        return
                }

                keys, err := redisSvc.GetAllRoomConfigKeys()
                if err != nil {
                        log.Printf("Failed to get all room config keys: %v", err)
                        http.Error(w, "Internal Server Error", http.StatusInternalServerError)
                        return
                }

                var allConfigs []models.RoomConfig
                for _, key := range keys {
                        var chatID int64
                        fmt.Sscanf(key, "room_config:%d", &chatID)

                        config, err := redisSvc.GetRoomConfig(chatID)
                        if err != nil {
                                log.Printf("Failed to get config for chat ID %d: %v", chatID, err)
                                continue
                        }
                        if config != nil {
                                allConfigs = append(allConfigs, *config)
                        }
                }

                w.Header().Set("Content-Type", "application/json")
                if err := json.NewEncoder(w).Encode(allConfigs); err != nil {
                        log.Printf("Failed to encode room configs: %v", err)
                        http.Error(w, "Internal Server Error", http.StatusInternalServerError)
                }
        })

        mux.HandleFunc("/admin/set_room_config", func(w http.ResponseWriter, r *http.Request) {
                if r.Method != http.MethodPost {
                        http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
                        return
                }

                var reqConfig models.RoomConfig
                if err := json.NewDecoder(r.Body).Decode(&reqConfig); err != nil {
                        http.Error(w, "Invalid request body", http.StatusBadRequest)
                        return
                }

                if err := redisSvc.SaveRoomConfig(&reqConfig); err != nil {
                        log.Printf("無法保存聊天室配置: %v", err)
                        http.Error(w, "Internal Server Error", http.StatusInternalServerError)
                        return
                }
                w.WriteHeader(http.StatusOK)
                fmt.Fprintf(w, "聊天室 %d 配置已更新。", reqConfig.ChatID)
                log.Printf("聊天室 %d 配置已更新。", reqConfig.ChatID)
        })

        mux.HandleFunc("/admin/delete_room_config", func(w http.ResponseWriter, r *http.Request) {
                if r.Method != http.MethodPost {
                        http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
                        return
                }

                var req struct {
                        ChatID int64 `json:"chat_id"`
                }
                if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
                        http.Error(w, "Invalid request body", http.StatusBadRequest)
                        return
                }

                if err := redisSvc.DeleteRoomConfig(req.ChatID); err != nil {
                        log.Printf("無法刪除聊天室 %d 配置: %v", req.ChatID, err)
                        http.Error(w, "Internal Server Error", http.StatusInternalServerError)
                        return
                }
                if err := redisSvc.ClearMessages(req.ChatID); err != nil {
                        log.Printf("無法清除聊天室 %d 歷史訊息: %v", req.ChatID, err)
                }
                w.WriteHeader(http.StatusOK)
                fmt.Fprintf(w, "聊天室 %d 配置及歷史訊息已刪除。", req.ChatID)
                log.Printf("聊天室 %d 配置及歷史訊息已刪除。", req.ChatID)
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
echo "========================================"
echo "          管理員 API 說明 (⚠️ 警告: 無身份驗證！)"
echo "========================================"
echo "這些 API 接口目前沒有任何身份驗證機制。在生產環境中，**強烈建議您為這些接口添加身份驗證！**"
echo ""
echo "### 1. 獲取所有聊天室配置"
echo "   \`GET http://localhost:8080/admin/rooms\`"
echo ""
echo "### 2. 設定/更新聊天室配置"
echo "   \`POST http://localhost:8080/admin/set_room_config\`"
echo "   **請求 Body (JSON)**:"
echo "   \`\`\`json"
echo "   {"
echo "     \"chat_id\": YOUR_TELEGRAM_CHAT_ID,"
echo "     \"api_key\": \"YOUR_AZURE_OPENAI_API_KEY_FOR_THIS_CHAT\","
echo "     \"approved\": true,"
echo "     \"model_name\": \"gpt-4.1-nano\""
echo "   }"
echo "   \`\`\`"
echo "   * 將 \`YOUR_TELEGRAM_CHAT_ID\` 替換為實際的 Telegram 聊天室 ID。"
echo "   * 將 \`YOUR_AZURE_OPENAI_API_KEY_FOR_THIS_CHAT\` 替換為該聊天室專用的 OpenAI API 金鑰。"
echo "   * \`approved\` 設為 \`true\` 表示啟用該聊天室的 AI 功能。"
echo "   * \`model_name\` 可以是您在 Azure OpenAI 中部署的模型名稱，例如 \`gpt-4.1-nano\` 等。"
echo ""
echo "### 3. 刪除聊天室配置"
echo "   \`POST http://localhost:8080/admin/delete_room_config\`"
echo "   **請求 Body (JSON)**:"
echo "   \`\`\`json"
echo "   {"
echo "     \"chat_id\": YOUR_TELEGRAM_CHAT_ID"
echo "   }"
echo "   \`\`\`"
echo ""
echo "### 聊天室啟用流程"
echo "1.  使用者在 Telegram 中向您的機器人發送 \`/start\`。"
echo "2.  機器人會將該聊天室 ID 記錄到 Redis，但狀態為 \`approved: false\` 且 \`api_key\` 為空。"
echo "3.  管理員透過上述 \`/admin/set_room_config\` API 手動將該聊天室的 \`approved\` 設為 \`true\` 並填入 \`api_key\` (可選) 和 \`model_name\`。"
echo "    * 例如，為聊天室 \`-491011\` 啟用 AI，您可以發送以下 POST 請求到 \`http://localhost:8080/admin/set_room_config\`："
echo "      \`\`\`json"
echo "      {"
echo "        \"chat_id\": -491011,"
echo "        \"api_key\": \"OGakAh\","
echo "        \"approved\": true,"
echo "        \"model_name\": \"gpt-4.1-nano\""
echo "      }"
echo "      \`\`\`"
echo "4.  聊天室被啟用後，使用者即可開始與 AI 機器人互動。"
echo ""
exit 0
