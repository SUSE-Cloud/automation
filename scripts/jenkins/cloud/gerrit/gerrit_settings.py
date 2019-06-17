import json
import os


def gerrit_settings():
    settings_filepath = os.path.join(os.path.dirname(__file__),
                                     'gerrit-settings.json')
    with open(settings_filepath) as settings_file:
        settings = json.load(settings_file)
    return settings


def gerrit_project_map(branch):
    return gerrit_settings()[branch]['project-map']


def obs_project_settings(branch):
    return gerrit_settings()[branch]['obs-project']
