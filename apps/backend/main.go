package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var db *pgxpool.Pool

type Item struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

func ensureSchema(ctx context.Context) error {
	_, err := db.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS items (
			id         SERIAL PRIMARY KEY,
			name       TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`)
	return err
}

// health is the liveness check: cheap and local. It only proves the process
// is responsive — it must NOT touch external dependencies like the database,
// or a DB outage would restart every pod (CrashLoopBackOff) without fixing anything.
func health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"version": "1.0.0",
	})
}

// ready is the readiness check: it verifies the pod can actually serve traffic
// by pinging the database. On failure K8s removes the pod from the Service
// (no traffic) but keeps it alive, so it recovers on its own when the DB returns.
func ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := db.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "not ready",
			"reason": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func listItems(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query(r.Context(), "SELECT id, name, created_at FROM items ORDER BY id")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	items := []Item{}
	for rows.Next() {
		var it Item
		if err := rows.Scan(&it.ID, &it.Name, &it.CreatedAt); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		items = append(items, it)
	}
	if rows.Err() != nil {
		http.Error(w, rows.Err().Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, items)
}

func createItem(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if in.Name == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}

	var it Item
	err := db.QueryRow(r.Context(),
		"INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at",
		in.Name,
	).Scan(&it.ID, &it.Name, &it.CreatedAt)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusCreated, it)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func main() {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}

	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		log.Fatalf("unable to create connection pool: %v", err)
	}
	defer pool.Close()
	db = pool

	if err := db.Ping(context.Background()); err != nil {
		log.Fatalf("unable to reach database: %v", err)
	}
	log.Println("connected to database")

	if err := ensureSchema(context.Background()); err != nil {
		log.Fatalf("unable to ensure schema: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", health)
	mux.HandleFunc("GET /ready", ready)
	mux.HandleFunc("GET /api/items", listItems)
	mux.HandleFunc("POST /api/items", createItem)

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}
