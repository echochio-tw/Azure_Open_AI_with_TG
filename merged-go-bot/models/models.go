package models

type RoomConfig struct {
	ChatID    int64  `json:"chat_id"`
	APIKey    string `json:"api_key"`
	Approved  bool   `json:"approved"`
	ModelName string `json:"model_name"`
}

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
