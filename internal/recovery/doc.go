// Package recovery constrains a one-shot pgBackRest restore to an approved database
// and backup set. Optional SQL verification runs offline at backup consistency;
// promotion and application cutover have separate owners.
package recovery
