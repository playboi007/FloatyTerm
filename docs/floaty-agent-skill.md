---
name: floaty-agent
description: >-
  Terminal-focused agent assistance for the FloatyTerm ecosystem — smart command
  suggestions, shell command explanation, safety checks for destructive
  commands, pipeline construction, log and error analysis, workflow
  optimization, and FloatyTerm integration. Use when working in terminals,
  analyzing shell output, building command pipelines, debugging build or
  deployment logs, or when the user mentions FloatyTerm, floaty CLI, or
  terminal workflows.
---

# FloatyAgent Skill

A terminal-focused agent skill for the FloatyTerm ecosystem - providing intelligent terminal assistance, command analysis, and workflow optimization for modern terminal workflows.

## Overview

The FloatyAgent skill bridges the gap between AI assistance and terminal-based development. It provides specialized capabilities for working within terminal environments, understanding shell commands, analyzing logs, and optimizing terminal workflows.

## Installation

To install this skill:

```bash
npx skills add <owner>/FloatyTerm@floaty-agent
```

Once installed, the skill will be available for use through the Skills CLI.

## Key Features

### 1. Command Intelligence
- **Smart Command Suggestions**: Context-aware command recommendations based on project structure and task
- **Command Explanation**: Break down complex shell commands into understandable steps
- **Safety Checks**: Warn about potentially destructive commands (rm -rf, format operations, etc.)
- **Alias Detection**: Understand and suggest useful terminal aliases

### 2. Workflow Optimization
- **Session History Analysis**: Learn from your terminal history to suggest improvements
- **Pipeline Construction**: Help build and optimize command pipelines
- **Environment Setup**: Guide through tool installations and environment configuration
- **Task Automation**: Identify repetitive patterns and suggest automation opportunities

### 3. Log & Output Analysis
- **Error Pattern Recognition**: Quickly identify and explain errors in terminal output
- **Stack Trace Parsing**: Extract meaningful information from complex stack traces
- **Performance Insights**: Analyze command timing and suggest optimizations
- **Build Output Review**: Parse and explain build/test output

### 4. Terminal Navigation
- **Directory Context**: Understand project structure and navigate efficiently
- **File Operations**: Smart suggestions for file management tasks
- **Remote Development**: Optimize SSH, Docker, and container workflows
- **Git Integration**: Enhanced git workflow assistance from the terminal

## Usage Examples

### Example 1: Command Safety Check
```bash
# User types:
rm -rf node_modules && npm install

# FloatyAgent provides:
✓ Safe to execute - will remove node_modules and reinstall dependencies
? Backup package.json first? (y/n)
```

### Example 2: Pipeline Construction
```bash
# User asks: "How do I find all Python files modified in the last week and count their lines?"

# FloatyAgent suggests:
find . -name "*.py" -type f -mtime -7 -exec wc -l {} + | sort -rn

# With explanation:
# 1. find . - Search from current directory
# 2. -name "*.py" - Filter Python files
# 3. -mtime -7 - Modified within last 7 days
# 4. -exec wc -l {} + - Count lines for each file
# 5. sort -rn - Sort by line count (descending)
```

### Example 3: Error Analysis
```bash
# Terminal shows:
ERROR: Could not find a version that satisfies the requirement package-name

# FloatyAgent analyzes:
→ Package not found in PyPI
→ Possible causes:
  - Typo in package name
  - Package is private/internal
  - Network/connectivity issue
→ Suggested fixes:
  1. Check spelling: pip search <package-name>
  2. Check if private: verify repository configuration
  3. Check index: pip install --index-url <url> <package>
```

## Integration with FloatyTerm

This skill is designed to work seamlessly with the FloatyTerm terminal emulator:

- **Context Awareness**: Understands the active terminal session and current working directory
- **Inline Assistance**: Provides help without disrupting workflow
- **Smart History**: Learns from command history across sessions
- **Visual Enhancements**: Leverages FloatyTerm's UI for better output formatting

## Configuration

### Basic Configuration
```json
{
  "floatyAgent": {
    "safetyChecks": true,
    "commandSuggestions": true,
    "logAnalysis": true,
    "verbosity": "normal",
    "shell": "auto-detect"
  }
}
```

### Environment Variables
- `FLOATY_AGENT_VERBOSITY`: Control output detail level (`quiet`, `normal`, `verbose`)
- `FLOATY_AGENT_SAFETY_MODE`: Enable/disable safety checks (`strict`, `warn`, `off`)
- `FLOATY_TERM_SESSION_ID`: Automatic session tracking for FloatyTerm

## Common Use Cases

### Development Workflow
- Setting up new project environments
- Debugging build and dependency issues
- Optimizing development toolchains
- Managing package installations

### DevOps & Operations
- Analyzing deployment logs
- Debugging container builds
- Managing infrastructure commands
- Monitoring system health

### Data & Analytics
- Building data processing pipelines
- Analyzing command performance
- Managing file operations at scale
- Automating repetitive tasks

### Learning & Exploration
- Understanding unfamiliar commands
- Exploring new tools and workflows
- Learning shell best practices
- Discovering command-line utilities

## Best Practices

1. **Review Before Execute**: Always review suggested commands before running
2. **Start Simple**: Use the skill for straightforward tasks first
3. **Provide Context**: The more context you give, the better the suggestions
4. **Learn from Explanations**: Read the "why" behind suggestions to build skills
5. **Customize**: Adjust settings to match your workflow preferences

## Troubleshooting

### Skill Not Responding
- Verify installation: `npx skills list`
- Check FloatyTerm connection: Ensure terminal session is active
- Review logs: Check FloatyTerm debug output

### Incorrect Suggestions
- Provide more context in your queries
- Check shell configuration
- Review and adjust skill settings

### Performance Issues
- Reduce verbosity level
- Limit history analysis depth
- Check system resources

## Advanced Features

### Custom Command Templates
Create reusable command templates:
```bash
# Define template
floaty template add deploy-prod "npm run build && npm run migrate && pm2 restart all"

# Use template
floaty run deploy-prod
```

### Workflow Scripts
Automate multi-step workflows:
```bash
# Define workflow
floaty workflow create setup-dev-env
  ├── Check prerequisites
  ├── Install dependencies
  ├── Configure environment
  └── Run tests

# Execute workflow
floaty workflow run setup-dev-env
```

## Support & Resources

- **Documentation**: https://skills.sh/FloatyTerm/floaty-agent
- **Issue Tracker**: https://github.com/<owner>/FloatyTerm/issues
- **Community**: Join our Discord for tips and support
- **Examples**: See `/examples/floaty-agent/` for practical use cases

## Contributing

We welcome contributions! Areas for enhancement include:
- Additional shell support (fish, zsh, PowerShell)
- Enhanced log analysis patterns
- New workflow templates
- Integration with more development tools

## License

This skill is part of the FloatyTerm project. See LICENSE for details.

---

**Skill Version**: 1.0.0  
**Last Updated**: 2026-06-27  
**Compatibility**: FloatyTerm 2.0+, Skills CLI 1.0+