---
name: calculate-hash
description: Calculate the hash of a given text.
---

# Calculate hash

This skill calculates the hash of a given text.

## Examples

* "Calculate hash of..."
* "What is the hash of..."

## Instructions

Call the `run_js` tool with the following exact parameters:

- skillName: `calculate-hash`
- data: A JSON string with the following field
  - text: the text to calculate hash for
