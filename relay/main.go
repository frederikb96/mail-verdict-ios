// Command mail-verdict-push-relay forwards encrypted push notifications to Apple on behalf of
// any self-hosted MailVerdict server. See README.md for the API contract and the security
// properties this design relies on.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := LoadConfig()
	if err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	pusher, err := NewAPNSPusher(cfg.APNSAuthKeyPath, cfg.APNSKeyID, cfg.APNSTeamID, cfg.APNSTopic, cfg.FallbackAlertTitle, cfg.FallbackAlertBody)
	if err != nil {
		log.Error("could not build APNs client", "error", err)
		os.Exit(1)
	}

	metrics := NewMetrics()
	limiters := NewRateLimiters(cfg.RateLimits)
	server := NewServer(cfg.TicketKeys, time.Duration(cfg.TicketTTLDays)*24*time.Hour, pusher, limiters, metrics, log, cfg.MaxBodyBytes, cfg.MaxBlobChars)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	done := make(chan struct{})
	limiters.StartSweeper(done, 10*time.Minute)
	defer close(done)

	httpServer := &http.Server{Addr: cfg.ListenAddr, Handler: server.Handler()}
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("http server failed", "error", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Error("error during shutdown", "error", err)
	}
}
