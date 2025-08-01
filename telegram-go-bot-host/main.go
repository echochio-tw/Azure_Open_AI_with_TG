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

		var reqConfig struct {
			ChatID   int64 `json:"chat_id"`
			Approved bool  `json:"approved"`
		}
		if err := json.NewDecoder(r.Body).Decode(&reqConfig); err != nil {
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}

		newConfig := models.RoomConfig{
			ChatID:    reqConfig.ChatID,
			Approved:  reqConfig.Approved,
			APIKey:    cfg.AzureOpenAIAPIKey,
			ModelName: cfg.DefaultOpenAIDeploymentName,
		}

		if err := redisSvc.SaveRoomConfig(&newConfig); err != nil {
			log.Printf("無法保存聊天室配置: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "聊天室 %d 配置已更新。", newConfig.ChatID)
		log.Printf("聊天室 %d 配置已更新。", newConfig.ChatID)
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
