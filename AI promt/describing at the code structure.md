# AI CODE GENERATION CONTRACT

## TASK
Generate a code example in any programming language for the requested task.

The implementation must be self-describing at the code structure level. All identifiers must encode their runtime meaning and system responsibility directly in their naming.

---

## NAMING SEMANTIC REQUIREMENTS

Every identifier must describe:

- Data/domain role
- Functional responsibility in execution flow
- Reason for existence in system architecture
- Interaction context with other components

Applies to:
- Variables
- Objects / dictionaries / maps
- Function parameters
- Loop variables
- Configuration keys (JSON / YAML / TOML / etc.)
- Nested fields and structures

---

## UNDER-THE-HOOD ENGINEERING RULES

- Code must represent production-level structure, not pseudo-code
- Naming must reflect system-level semantics, not short aliases
- Identifier naming must act as inline architecture documentation
- Prefer explicit long-form identifiers that fully describe behavior and responsibility
- Maintain consistency across all abstraction layers (logic, config, data, control flow)

---

## CONSTRAINTS

- No comments allowed
- No explanations outside code output
- No markdown text except code block output
- Must keep valid syntax for selected programming language
- Do not rename reserved keywords or framework-required identifiers
 - but reflect their meaning in surrounding context through naming

---

## OUTPUT FORMAT

Return ONLY executable code.

No explanations. No commentary. No extra text.

---

## OBJECTIVE

The final code must be readable purely through structure and naming, functioning as both:

- Working implementation
- Architectural documentation (self-documenting system design)

