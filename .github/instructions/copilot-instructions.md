---
applyTo: '**'
---
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

---
applyTo: '**/*.lisp'
---
Use snake_case for variable and function names (e.g. my_variable_name, my_function_name).
Use `!=` for inequality comparisons.
Use `=` for equality comparisons.
Use `and` for logical AND.
Use `or` for logical OR.
Use `not` for logical NOT.
Multiple nested `if` statements should be replaced with `cond` statements.
