// Package contracttest validates HTTP responses against api/openapi.yaml.
// Only tests import it, so the validator never reaches the agent binary.
package contracttest

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/pb33f/libopenapi"
	validator "github.com/pb33f/libopenapi-validator"
)

// Middleware returns a wrapper that fails the test whenever the wrapped
// handler answers with a response the contract does not describe.
func Middleware(t testing.TB) func(http.Handler) http.Handler {
	t.Helper()
	// The source file is read rather than the embedded copy, so the check
	// does not depend on the generator having preserved the schema.
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate contracttest source")
	}
	specPath := filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "api", "openapi.yaml")
	spec, err := os.ReadFile(specPath) //nolint:gosec // fixed path inside the repository
	if err != nil {
		t.Fatalf("read contract: %v", err)
	}
	document, err := libopenapi.NewDocument(spec)
	if err != nil {
		t.Fatalf("parse contract: %v", err)
	}
	contract, errs := validator.NewValidator(document)
	if len(errs) > 0 {
		t.Fatalf("build contract validator: %v", errs)
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			recorder := httptest.NewRecorder()
			next.ServeHTTP(recorder, r)

			response := recorder.Result()
			if valid, violations := contract.ValidateHttpResponse(r, response); !valid {
				for _, violation := range violations {
					t.Errorf("%s %s -> %d violates the contract: %s: %s",
						r.Method, r.URL.Path, recorder.Code, violation.Message, violation.Reason)
				}
			}

			for name, values := range recorder.Header() {
				w.Header()[name] = values
			}
			w.WriteHeader(recorder.Code)
			_, _ = w.Write(recorder.Body.Bytes())
		})
	}
}
