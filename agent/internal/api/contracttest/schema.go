package contracttest

import (
	"os"
	"testing"

	"github.com/pb33f/libopenapi"
	"github.com/pb33f/libopenapi-validator/schema_validation"
)

// RequireSchema fails the test unless payload is a valid instance of the
// named components.schemas entry. WebSocket payloads bypass the HTTP
// validator, so topic tests check them with this.
func RequireSchema(t testing.TB, name string, payload []byte) {
	t.Helper()
	spec, err := os.ReadFile(RepoPath("api", "openapi.yaml"))
	if err != nil {
		t.Fatalf("read contract: %v", err)
	}
	document, err := libopenapi.NewDocument(spec)
	if err != nil {
		t.Fatalf("parse contract: %v", err)
	}
	model, err := document.BuildV3Model()
	if err != nil {
		t.Fatalf("build contract model: %v", err)
	}
	proxy, ok := model.Model.Components.Schemas.Get(name)
	if !ok {
		t.Fatalf("no schema %s in the contract", name)
	}
	schema, err := proxy.BuildSchema()
	if err != nil {
		t.Fatalf("build schema %s: %v", name, err)
	}
	if valid, errs := schema_validation.NewSchemaValidator().ValidateSchemaBytes(schema, payload); !valid {
		for _, e := range errs {
			t.Errorf("%s is not a valid %s: %s", payload, name, describe(e.Reason, e.SchemaValidationErrors))
		}
	}
}
