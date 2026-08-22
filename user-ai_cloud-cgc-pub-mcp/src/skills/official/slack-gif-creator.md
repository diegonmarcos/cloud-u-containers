---
id: skill-slack-gif
type: skill
name: "Slack GIF Creator"
path: slack-gif-creator
summary: "Animated GIFs for Slack"
category: "Design & Creative"
source: anthropics/skills
requiredMcp:
  - Write
  - Bash
parameters:
  - name: GIFBuilder
    type: "Python class"
    required: true
    description: "Assemble and optimize GIFs"
  - name: validators
    type: "Python module"
    required: true
    description: "validate_gif(), is_slack_ready()"
  - name: easing
    type: "Python module"
    required: true
    description: "interpolate() with 7 easing types"
  - name: "pillow/imageio"
    type: Python
    required: true
    description: "pip install pillow imageio numpy"
---

# Slack GIF Creator

Create Slack-optimized GIFs using GIFBuilder, validators, and easing functions. Emoji: 128x128, 10-30fps, 48-128 colors, <3s. Message: 480x480. PIL for drawing, built-in animations: shake, pulse, bounce, spin, fade, zoom, particles.

## Example Prompts

- "Create an animated Slack emoji of a spinning loading indicator"
- "Make a pulsing heart GIF optimized for Slack emoji size"
- "Build a bouncing text animation that says 'LGTM' for Slack"
- "Generate a party parrot style celebration GIF for Slack reactions"
