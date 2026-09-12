package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

// Metrics is the whole observability surface, matching README.md's API section exactly — that
// document is the contract; these names are its implementation. Registered against a private
// registry rather than the global default, so tests can create a fresh Metrics per test without
// a "duplicate metrics collector registration" panic.
type Metrics struct {
	registry *prometheus.Registry

	PushTotal        *prometheus.CounterVec
	RegisterTotal    *prometheus.CounterVec
	RateLimitedTotal *prometheus.CounterVec
}

func NewMetrics() *Metrics {
	m := &Metrics{registry: prometheus.NewRegistry()}

	m.PushTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mvrelay_push_total",
		Help: "Push attempts through /v1/push, by type and result.",
	}, []string{"type", "result"})

	m.RegisterTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mvrelay_register_total",
		Help: "Calls to /v1/register, by result.",
	}, []string{"result"})

	m.RateLimitedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mvrelay_ratelimited_total",
		Help: "Requests rejected with 429, by which scope's bucket tripped.",
	}, []string{"scope"})

	m.registry.MustRegister(m.PushTotal, m.RegisterTotal, m.RateLimitedTotal)
	return m
}
