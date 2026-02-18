package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/diegonmarcos/go-api/config"
	"github.com/diegonmarcos/go-api/routes"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func main() {
	port := os.Getenv("GO_API_PORT")
	if port == "" {
		port = "8090"
	}

	cfg := config.Load()

	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(corsMiddleware)

	routes.RegisterHealth(r, cfg)
	routes.RegisterProfiling(r, cfg)
	routes.RegisterActions(r, cfg)
	routes.RegisterDocs(r, cfg)

	addr := fmt.Sprintf("0.0.0.0:%s", port)
	log.Printf("Go API listening on %s", addr)
	if err := http.ListenAndServe(addr, r); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
