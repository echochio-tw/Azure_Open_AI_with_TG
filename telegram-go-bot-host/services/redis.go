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
