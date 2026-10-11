# AI Policy

AI is a powerful tool. However, all contributions to CloudStream for macOS must adhere to these rules in order to guarantee the safety, quality, and architectural integrity of the codebase:

1. **Disclose AI Usage:** Always state if and how AI tools were used in pull requests, issues, and commit messages.
2. **Empirical Verification Required:** Always build (`make build`) and test (`make test`) code before submitting. We do not test unverified or hallucinatory AI-generated code.
3. **Listen to Humans Over Models:** Maintainers and domain contributors understand this codebase and macOS system APIs better than language models.
4. **Defend Your Changes:** You must be able to explain, debug, and justify every architectural pattern, line of code, and configuration parameter you submit. Low-effort or unreviewed submissions will be rejected.
