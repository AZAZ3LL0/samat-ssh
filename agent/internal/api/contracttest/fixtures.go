package contracttest

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/pb33f/libopenapi"
	liberrors "github.com/pb33f/libopenapi-validator/errors"
	"github.com/pb33f/libopenapi-validator/schema_validation"
)

// ValidateFixtures checks every file under dir against the contract schema its
// directory names: host_metrics/*.json holds HostMetrics documents and
// logs/*.jsonl one LogEntry per line. It returns one message per violation;
// the error reports only failures to read the inputs.
func ValidateFixtures(spec []byte, dir string) ([]string, error) {
	document, err := libopenapi.NewDocument(spec)
	if err != nil {
		return nil, fmt.Errorf("parse contract: %w", err)
	}
	model, err := document.BuildV3Model()
	if err != nil {
		return nil, fmt.Errorf("build contract model: %w", err)
	}
	schemas := model.Model.Components.Schemas
	validator := schema_validation.NewSchemaValidator()

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read fixtures: %w", err)
	}
	var violations []string
	for _, entry := range entries {
		if !entry.IsDir() {
			violations = append(violations, fmt.Sprintf("%s: fixtures live in a directory named after their schema", entry.Name()))
			continue
		}
		name := schemaName(entry.Name())
		proxy, ok := schemas.Get(name)
		if !ok {
			violations = append(violations, fmt.Sprintf("%s: no schema %s in the contract", entry.Name(), name))
			continue
		}
		schema, err := proxy.BuildSchema()
		if err != nil {
			return nil, fmt.Errorf("build schema %s: %w", name, err)
		}

		files, err := filepath.Glob(filepath.Join(dir, entry.Name(), "*"))
		if err != nil {
			return nil, fmt.Errorf("list %s: %w", entry.Name(), err)
		}
		sort.Strings(files)
		if len(files) == 0 {
			violations = append(violations, fmt.Sprintf("%s: empty fixture directory", entry.Name()))
		}
		for _, file := range files {
			documents, err := readDocuments(file)
			if err != nil {
				return nil, err
			}
			rel, _ := filepath.Rel(dir, file)
			if documents == nil {
				violations = append(violations, fmt.Sprintf("%s: fixtures are .json or .jsonl files", rel))
			}
			for i, payload := range documents {
				where := rel
				if strings.HasSuffix(file, ".jsonl") {
					where = fmt.Sprintf("%s:%d", rel, i+1)
				}
				if valid, errs := validator.ValidateSchemaBytes(schema, payload); !valid {
					for _, e := range errs {
						violations = append(violations, fmt.Sprintf("%s: not a valid %s: %s", where, name, describe(e.Reason, e.SchemaValidationErrors)))
					}
				}
			}
		}
	}
	return violations, nil
}

// readDocuments returns the JSON documents in file, or nil for a file that is
// neither .json nor .jsonl.
func readDocuments(file string) ([][]byte, error) {
	data, err := os.ReadFile(file) //nolint:gosec // paths come from the fixtures directory
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", file, err)
	}
	switch filepath.Ext(file) {
	case ".json":
		return [][]byte{data}, nil
	case ".jsonl":
		documents := [][]byte{}
		scanner := bufio.NewScanner(bytes.NewReader(data))
		scanner.Buffer(nil, 1<<20)
		for scanner.Scan() {
			documents = append(documents, bytes.Clone(scanner.Bytes()))
		}
		if err := scanner.Err(); err != nil {
			return nil, fmt.Errorf("read %s: %w", file, err)
		}
		return documents, nil
	default:
		return nil, nil
	}
}

// schemaName maps a fixture directory to its schema: host_metrics → HostMetrics.
func schemaName(dir string) string {
	var b strings.Builder
	for _, part := range strings.Split(dir, "_") {
		if part != "" {
			b.WriteString(strings.ToUpper(part[:1]) + part[1:])
		}
	}
	return b.String()
}

func describe(reason string, details []*liberrors.SchemaValidationFailure) string {
	parts := []string{reason}
	for _, d := range details {
		parts = append(parts, d.Error())
	}
	return strings.Join(parts, "; ")
}
