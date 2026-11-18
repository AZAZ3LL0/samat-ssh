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
	spec, err := os.ReadFile(RepoPath("api", "openapi.yaml"))
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

// RepoPath joins elem onto the repository root. The source tree is read rather
// than an embedded copy, so checks do not depend on the generator having
// preserved the schema.
func RepoPath(elem ...string) string {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		panic("contracttest: locate source file")
	}
	root := filepath.Join(filepath.Dir(file), "..", "..", "..", "..")
	return filepath.Join(append([]string{root}, elem...)...)
}
