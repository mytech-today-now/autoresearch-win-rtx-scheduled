You are an expert prompt engineer and AI optimization specialist with deep knowledge of large language model capabilities, limitations, and best practices. Your goal is to transform any given user prompt into the highest-quality, most effective version possible.
Task:
Refactor the following prompt to make it the absolute best it can be. Produce only the final improved prompt as your output (no explanations, no wrappers, no commentary unless explicitly requested).

Core Principles to Apply:

Clarity & Precision: Eliminate ambiguity. Use specific, unambiguous language. Define roles, goals, constraints, and success criteria explicitly.
Structure & Readability: Organize the prompt logically (e.g., Role → Objective → Guidelines → Examples → Output Format → Constraints). Use clear headings, bullet points, or numbered steps when helpful.
Completeness: Infer and include any important instructions that appear to be missing or implied. Common omissions to address include: chain-of-thought requirements, step-by-step reasoning, few-shot examples, output formatting specifications, tone/style guidelines, length/token constraints, error-handling, and evaluation criteria.
Effectiveness: Incorporate advanced prompt engineering techniques such as:
Role assignment (e.g., "You are a world-class...").
Explicit reasoning instructions (e.g., "Think step-by-step before answering.").
Few-shot or chain-of-thought examples when relevant.
Positive and negative guidance (what to do and what to avoid).
Constraints on hallucinations, verbosity, or off-topic responses.
Desired output format (JSON, markdown, tables, etc.) with examples.

Conciseness with Depth: Be verbose and detailed where it adds value (explanations, examples, edge cases), but never redundant. Remove fluff while preserving richness.
Token Awareness: Optimize for efficiency. Suggest or enforce appropriate token ranges when relevant (e.g., "Respond in 200-400 tokens" or "Use 800-1500 tokens for a comprehensive answer").
Adaptability: Tailor the prompt to the apparent intent of the original while enhancing it. If the original prompt is meta or recursive, preserve and strengthen that nature.

Input Format:
The prompt to refactor will be provided after the label "ORIGINAL PROMPT:".
Output Requirements:

Return ONLY the complete, ready-to-use refactored prompt.
Enclose it in a clean markdown code block labeled ```prompt```
Ensure the refactored prompt is self-contained and immediately usable with any capable LLM.
Maintain the original goal and spirit while dramatically improving quality, robustness, and performance.

ORIGINAL PROMPT:
"""

refactor the Repo to use the AI power from 'ai-powered' (https://www.npmjs.com/package/ai-powered) rather than the AI from  augmentcode AI or any other AI source.
The repo should be refactored so that it only runs on a Windows Schedule, when the computer is idle.  the name of the scheduled task is called 'autoresearch-karpathy' in the '\myTech.Today' Scheduled Task Folder.  The author of the scheduled task will be "myTech.Today (sales@mytech.today)".  the Description will be an AI version of the this: [The tasks runs Andrej Karpathy's autoresearch repo (https://github.com/karpathy/autoresearch) as a scheduled task whenever the computer is idle, on Windows.]
The refactoring should create a ps1 launch script 'scripts/launch.ps1' that launches the application, with all necessary dependencies either already in place or added as necessary.  If the scheduled task doesn't exist, the 'launch.ps1' script will create it.  The 'launch.ps1' script will also be used to remove the scheduled task.  The launch script will update itself with '-update', which will update with the latest 'https://github.com/karpathy/autoresearch' but also the latest version of this repo itself.  The 'launch.ps1' script will also have a '-version', '-debug', which will put the errors and debug info to a '%HOMEDRIVE%\myTech.Today\logs\autoresearch-karpathy.jsonl' file for the output regarding 'autoresearch-karpathy' and the scheduled task issues.



   A windows shortcut .lnk file 'autoresearch.lnk' will also be created that launches the 'launch.ps1' script.  The 'launch.ps1' script will be used also to cycle the 'autoresearch' program if it is not working or needs to be restarted.  Running it again will not create another scheduled task.

The scheduled tasks will be added.  The process will check to makes sure that it runs properly then pause and wait for the next time the scheduled tasks wakes up the processing to begin again during idle times.



"""


Be verbose and detailed, but not redundant.  Include the instructions that I forgot to include.
Now, refactor the prompt above following all guidelines.
Reply with a refactored prompt in file 'refactor-autoresearch.md' in code block format.