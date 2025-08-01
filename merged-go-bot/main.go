package main

import (
	"log"
	"net/http"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"github.com/joho/godotenv"

	"merged-go-bot/config"
	"merged-go-bot/handlers"
	"merged-go-bot/services"
)

func main() {
	err := godotenv.Load(".env")
	if err != nil {
		log.Fatal("錯誤：無法載入 .env 檔案")
	}

	cfg := config.LoadConfig()
	
	bot, err := tgbotapi.NewBotAPI(cfg.TelegramBotToken)
	if err != nil {
		log.Fatalf("無法連接到 Telegram 機器人: %v", err)
	}
	bot.Debug = true
	log.Printf("已授權帳號: %s", bot.Self.UserName)

	redisSvc := services.NewRedisService(cfg.RedisAddr, cfg.RedisPassword, cfg.RedisDB)
	defer redisSvc.Close()

	openaiSvc := services.NewOpenAIService(cfg)
	soraSvc := services.NewSoraService(cfg, bot)

	handler := handlers.NewMergedHandler(cfg, redisSvc, openaiSvc, soraSvc, bot)
	
	log.Printf("Webhook URL: %s", cfg.TelegramWebhookURL)
	http.HandleFunc(cfg.TelegramWebhookPath, handler.HandleTelegramWebhook)
	
	log.Printf("伺服器正在 %s 上監聽...", cfg.ListenAddr)
	log.Fatal(http.ListenAndServe(cfg.ListenAddr, nil))
}
