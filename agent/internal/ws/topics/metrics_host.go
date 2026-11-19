// Package topics declares the WebSocket topics the agent serves, one file per topic.
package topics

import "github.com/AZAZ3LL0/samat-ssh/agent/internal/ws"

// MetricsHost streams a HostMetrics snapshot every second.
const MetricsHost = "metrics.host"

// RegisterMetricsHost makes metrics.host available on hub. It takes no parameters.
func RegisterMetricsHost(hub *ws.Hub) {
	hub.Register(ws.Topic{Name: MetricsHost})
}
