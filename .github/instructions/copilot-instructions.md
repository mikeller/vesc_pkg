---
applyTo: '**'
---
Only make the specific changes that the user has requested. If you identify other potential improvements, present them as suggestions at the end of your chat output rather than implementing them.
Maintainability is a priority - choose the easiest to  understand implementation without over-simplifying.
Only consider files in the `blacktip_dpv` directory unless otherwise specified.
When making code changes, if the input line has trailing whitespace, please remove it.
Never add whitespace at the end of a line, or on empty lines.
Brace style is 1TBS (One True Brace Style).
Closing braces go onto a new line, with the same indentation as the line containing the matching opening brace. The exception is for places where there are more than one opening braces (`(` or `{`) on a line, in which case all of the braces go on the same line.
Use 4 spaces for indentation, not tabs.
Use semver without a leading 'v' for version numbers (e.g. 1.2.3).
The 'then' and 'else' blocks of conditionals should start on a new line.
Comments are indented to the same level as the code they refer to.
No whitespace at the end of lines or on empty lines.
Never create standalone summary documents (e.g. SUMMARY.md, CHANGES.md, etc.) - add documentation to DEVELOPMENT.md for developers (only when this is needed for working on the code) or README.md for users instead.
If a Makefile with a tests target exists, run the tests after making changes to ensure nothing is broken.

---
applyTo: '**/*.lisp'
---
Use snake_case for variable and function names (e.g. my_variable_name, my_function_name).
Use `=` for numeric equality comparisons.
Use `!=` for numeric inequality comparisons.
Use `eq` for symbol/identity equality comparisons.
Use `not-eq` for symbol/identity inequality comparisons.
Use `and` for logical AND.
Use `or` for logical OR.
Use `not` for logical NOT.
Nested `if` statements covering more than one `if` should be replaced with `cond` statements. This does not apply to `if` statements that only have a single `if` but also and 'else' block.
