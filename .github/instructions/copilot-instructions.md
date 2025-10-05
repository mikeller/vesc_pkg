---
applyTo: '**'
---
Only consider files in the `blacktip_dpv` directory unless otherwise specified.
When making code changes, if the input line has trailing whitespace, please remove it.
Never add whitespace at the end of a line, or on empty lines.
Brace style is 1TBS (One True Brace Style).
Use 4 spaces for indentation, not tabs.
Use semver without a leading 'v' for version numbers (e.g. 1.2.3).

---
applyTo: '**/*.lisp'
---
Use lower space snake case for variable and function names (e.g. my_variable_name, my_function_name).
Closing braces go onto a new line, with the same indentation as the line containing the matching opening brace. The exception is for places where there are more than one opening braces (`(` or `{`) on a line, in which case all of the braces go on the same line.
Use `!=` for inequality comparisons, not `/=` or `<>` or `not-eq`.
Use `=` for equality comparisons, not `eq`.
Use `&&` for logical AND, not `and`.
Use `||` for logical OR, not `or`.
Use `!` for logical NOT, not `not`.