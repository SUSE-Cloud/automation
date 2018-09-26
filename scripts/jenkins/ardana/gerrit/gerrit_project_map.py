import json
import os


def gerrit_project_map():
    # Used for mapping gerrit project names onto OBS package names
    map_file = os.path.join(os.path.dirname(__file__), 'project-map.json')
    with open(map_file) as map:
        project_map = json.load(map)
    return project_map
