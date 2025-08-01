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
		AzureOpenAIAPIVersion:       "2024-12-01-preview",
		DefaultOpenAIDeploymentName: "gpt-4.1-nano",
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
