// Package recovery restores one exact pgBackRest backup set of an approved database, once, on a
// disposable recovery host, and can then verify the restored data offline at backup consistency.
//
// Putting restored data back into production is a separate change, planned and reviewed on its own.
package recovery
