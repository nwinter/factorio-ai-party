"""Apply an operator's exact-run speech trial to a freshly generated stream config."""
import copy
import json
import os
import sys

import voices

TRIAL_FILE = "/Users/owner/code/pog-operator/tts-trial.json"
PATHS = ("hosts", "agent_speech", "caster_fallback", "recap_service", "recap_cli",
         "tour_narration", "hourly_narration", "speech_cli")


def apply(config, run, path=None):
    path = path if path is not None else os.environ.get("POG_TTS_TRIAL_FILE", TRIAL_FILE)
    try:
        with open(path) as f:
            trial = json.load(f)
        if not isinstance(trial, dict) or trial.get("run") != run:
            return config
        model = voices.configured_openai_model({"audio": {"openai_tts_model": trial["openai_tts_model"]}})
    except FileNotFoundError:
        return config
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"[tts-trial] ignored invalid trial: {type(exc).__name__}", file=sys.stderr)
        return config
    prior = voices.configured_openai_model(config)
    result = copy.deepcopy(config)
    audio = result["audio"] = copy.deepcopy(config.get("audio") or {})
    result["tts_trial"] = {
        "run": run, "openai_tts_model": model,
        "prior_audio": copy.deepcopy(config.get("audio")),
        "paths": {name: {"prior_setting": audio.get("openai_tts_model"),
                         "prior_effective_model": prior, "trial_effective_model": model} for name in PATHS},
        "restore": "Every other run uses its freshly generated configuration; no trial is inherited.",
    }
    audio["openai_tts_model"] = model
    return result
