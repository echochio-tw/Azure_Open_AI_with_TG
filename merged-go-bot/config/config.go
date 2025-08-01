package config

import (
	"log"
	"os"
	"strconv"
)

type Config struct {
	ListenAddr string
	RedisAddr  string
	RedisPassword string
	RedisDB int
	TelegramBotToken string
	TelegramWebhookPath string
	TelegramWebhookURL string
	AzureOpenAIEndpoint string
	AzureOpenAIAPIKey string
	AzureOpenAIAPIVersionChat string
	DefaultOpenAIDeploymentName string
	ReservedForResponseTokens int
	ModelTokenLimits map[string]int
	MaxContextMessages int
	TokenWarningThreshold float64
	AzureOpenAISoraDeploymentName string
	AzureOpenAISoraAPIVersion string
	SoraDefaultWidth int
	SoraDefaultHeight int
	SoraDefaultNSeconds int
}

func LoadConfig() *Config {
	cfg := &Config{}
	
	cfg.ListenAddr = os.Getenv("LISTEN_ADDR")
	cfg.RedisAddr = os.Getenv("REDIS_ADDR")
	cfg.RedisPassword = os.Getenv("REDIS_PASSWORD")
	cfg.TelegramBotToken = os.Getenv("TELEGRAM_BOT_TOKEN")
	cfg.AzureOpenAIEndpoint = os.Getenv("AZURE_OPENAI_ENDPOINT")
	cfg.AzureOpenAIAPIKey = os.Getenv("AZURE_OPENAI_API_KEY")
	cfg.AzureOpenAIAPIVersionChat = os.Getenv("AZURE_OPENAI_API_VERSION_CHAT")
	cfg.DefaultOpenAIDeploymentName = os.Getenv("DEFAULT_OPENAI_DEPLOYMENT_NAME")
	cfg.AzureOpenAISoraDeploymentName = os.Getenv("AZURE_OPENAI_SORA_DEPLOYMENT_NAME")
	cfg.AzureOpenAISoraAPIVersion = os.Getenv("AZURE_OPENAI_SORA_API_VERSION")

	if cfg.ListenAddr == "" { cfg.ListenAddr = ":8081" }
	if cfg.RedisAddr == "" { cfg.RedisAddr = "127.0.0.1:6379" }
	if db, err := strconv.Atoi(os.Getenv("REDIS_DB")); err == nil {
		cfg.RedisDB = db
	} else {
		cfg.RedisDB = 3
	}
	if w, err := strconv.Atoi(os.Getenv("SORA_DEFAULT_WIDTH")); err == nil && w > 0 {
		cfg.SoraDefaultWidth = w
	} else {
		cfg.SoraDefaultWidth = 1920
	}
	if h, err := strconv.Atoi(os.Getenv("SORA_DEFAULT_HEIGHT")); err == nil && h > 0 {
		cfg.SoraDefaultHeight = h
	} else {
		cfg.SoraDefaultHeight = 1080
	}
	if s, err := strconv.Atoi(os.Getenv("SORA_DEFAULT_N_SECONDS")); err == nil && s > 0 {
		cfg.SoraDefaultNSeconds = s
	} else {
		cfg.SoraDefaultNSeconds = 10
	}

	cfg.TelegramWebhookPath = "/telegram_webhook/" + cfg.TelegramBotToken
	cfg.TelegramWebhookURL = os.Getenv("TELEGRAM_WEBHOOK_BASE_URL") + cfg.TelegramWebhookPath
	
	cfg.ReservedForResponseTokens = 500
	cfg.MaxContextMessages = 10
	cfg.TokenWarningThreshold = 0.9
	cfg.ModelTokenLimits = map[string]int{
		"gpt-35-turbo": 4096, "gpt-35-turbo-16k": 16384, "gpt-4": 8192,
		"gpt-4-32k": 32768, "gpt-4o": 128000, "gpt-4o-mini": 128000,
		"gpt-4.1-nano-deployment": 1000000, "gpt-4.1-nano": 1000000,
	}

	if cfg.TelegramBotToken == "" {
		log.Fatal("錯誤：TELEGRAM_BOT_TOKEN 環境變數未設定。")
	}
	if cfg.AzureOpenAIAPIKey == "" || cfg.AzureOpenAIEndpoint == "" {
		log.Fatal("錯誤：Azure API 相關環境變數未設定。")
	}

	log.Println("設定載入成功。")
	return cfg
}
