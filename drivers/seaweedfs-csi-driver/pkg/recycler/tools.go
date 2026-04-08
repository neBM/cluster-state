//go:build tools

// This file pins build-time dependencies that are not yet imported by
// production code. Remove once the packages are referenced directly.
package recycler

import (
	_ "sigs.k8s.io/controller-runtime/pkg/client"
	_ "github.com/prometheus/client_golang/prometheus"
	_ "k8s.io/api/core/v1"
)
