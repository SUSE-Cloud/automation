import json
import os


def gerrit_settings():
    settings_filepath = os.path.join(os.path.dirname(__file__),
                                     'gerrit-settings.json')
    with open(settings_filepath) as settings_file:
        settings = json.load(settings_file)
    return settings


def gerrit_project_map():
    return gerrit_settings()['project-map']


def obs_project_settings():
    return gerrit_settings()['obs-project']
