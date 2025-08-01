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
