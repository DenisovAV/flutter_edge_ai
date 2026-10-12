---
name: tip-split
description: Splits a restaurant bill, with tip, between several people. Use when the user asks how much each person pays.
---

# Tip split

## Examples

* "Split 84 dollars between 3 of us with a 15% tip"
* "We are four, the bill is 120 euros, 10 percent tip — how much each?"

## Instructions

Never do the arithmetic yourself. Call the `run_js` tool with:

- skillName: `tip-split`
- data: a JSON string with these fields
  - total: the bill before tip, as a number
  - people: how many people share it, as a whole number
  - tip_percent: the tip in percent, as a number; 0 if the user gave none
  - no other fields

Then tell the user what each person pays, using the numbers the tool returned.
