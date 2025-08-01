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
	"merged-go-bot/config"
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
	if _, err := os.Stat("tmp"); os.IsNotExist(err) {
		log.Println("Creating tmp directory for video files...")
		os.Mkdir("tmp", 0755)
	}
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
		"width":      strconv.Itoa(s.defaultWidth),
		"height":     strconv.Itoa(s.defaultHeight),
		"n_seconds":  strconv.Itoa(s.defaultNSeconds),
		"n_variants": strconv.Itoa(1),
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
