package driver

import (
	"testing"
)

func TestParseOwnershipAnnotation_Absent(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil pointer for absent annotation, got %d", *got)
	}
}

func TestParseOwnershipAnnotation_Empty(t *testing.T) {
	// Empty string value must be treated identically to absent.
	got, err := parseOwnershipAnnotation(map[string]string{"k": ""}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil for empty value, got %d", *got)
	}
}

func TestParseOwnershipAnnotation_Valid(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "990"}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || *got != 990 {
		t.Errorf("expected 990, got %v", got)
	}
}

func TestParseOwnershipAnnotation_Zero(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "0"}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || *got != 0 {
		t.Errorf("expected 0, got %v", got)
	}
}

func TestParseOwnershipAnnotation_Negative(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "-1"}, "k")
	if err == nil {
		t.Errorf("expected error for negative, got nil (value=%v)", got)
	}
}

func TestParseOwnershipAnnotation_NonInteger(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "990abc"}, "k")
	if err == nil {
		t.Errorf("expected error for non-integer, got nil (value=%v)", got)
	}
}

func TestParseOwnershipAnnotation_Overflow(t *testing.T) {
	// int32 max is 2147483647. 2147483648 must fail.
	got, err := parseOwnershipAnnotation(map[string]string{"k": "2147483648"}, "k")
	if err == nil {
		t.Errorf("expected overflow error, got nil (value=%v)", got)
	}
}
