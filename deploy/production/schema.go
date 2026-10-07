// Package production embeds the reviewed contracts used by operational tooling.
package production

import "embed"

// Schemas travel with the executable built before protected inputs are loaded.
//
//go:embed *.schema.json
var Schemas embed.FS
