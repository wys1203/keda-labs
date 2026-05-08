// cmd/keda-deprecation-webhook/main.go
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "keda-deprecation-webhook: stub, not yet wired")
	os.Exit(0)
}
