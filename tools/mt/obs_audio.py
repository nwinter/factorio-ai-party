"""Team-test scene mix, using the main stream's music slot and voice sidechain settings."""
MUSIC_FILE = r'D:\pog\music\bed.mp3'
# Same compressor as tools/obs.py stream_audio. Bed is mastered at -16 LUFS;
# -12 dB puts it near -28 LUFS between the main TTS engine's -18 LUFS speech.
MUSIC_DB = -12.0
DUCK = dict(ratio=2.5, threshold=-40.0, attack_time=15, release_time=700, output_gain=0.0)


def ensure_filter(obs, source, name, kind, settings):
    filters = obs.call('GetSourceFilterList', {'sourceName': source}).get('filters', [])
    if any(f['filterName'] == name for f in filters):
        obs.call('SetSourceFilterSettings', {'sourceName': source, 'filterName': name, 'filterSettings': settings, 'overlay': True})
        obs.call('SetSourceFilterEnabled', {'sourceName': source, 'filterName': name, 'filterEnabled': True})
    else:
        obs.call('CreateSourceFilter', {'sourceName': source, 'filterName': name, 'filterKind': kind, 'filterSettings': settings})


def setup_audio(obs, scene='mt-stream', overlay='mt overlay', bed='mt music bed', music_file=MUSIC_FILE):
    """Scene-local music and caster only. Never enable process/game audio or change main inputs."""
    settings = dict(is_local_file=True, local_file=music_file, looping=True,
                    restart_on_activate=True, close_when_inactive=True)
    inputs = {i['inputName'] for i in obs.call('GetInputList')['inputs']}
    if bed in inputs:
        obs.call('SetInputSettings', {'inputName': bed, 'inputSettings': settings, 'overlay': True})
        items = obs.call('GetSceneItemList', {'sceneName': scene})['sceneItems']
        if bed not in {i['sourceName'] for i in items}:
            obs.call('CreateSceneItem', {'sceneName': scene, 'sourceName': bed, 'sceneItemEnabled': True})
    else:
        obs.call('CreateInput', {'sceneName': scene, 'inputName': bed, 'inputKind': 'ffmpeg_source',
                                 'inputSettings': settings, 'sceneItemEnabled': True})
    item = obs.call('GetSceneItemId', {'sceneName': scene, 'sourceName': bed})['sceneItemId']
    obs.call('SetSceneItemEnabled', {'sceneName': scene, 'sceneItemId': item, 'sceneItemEnabled': True})
    obs.call('SetInputSettings', {'inputName': overlay, 'inputSettings': {'reroute_audio': True, 'shutdown': True}, 'overlay': True})
    for name, db in ((overlay, 0.0), (bed, MUSIC_DB)):
        obs.call('SetInputVolume', {'inputName': name, 'inputVolumeDb': db})
        obs.call('SetInputMute', {'inputName': name, 'inputMuted': False})
        obs.call('SetInputAudioMonitorType', {'inputName': name, 'monitorType': 'OBS_MONITORING_TYPE_NONE'})
        obs.call('SetInputAudioTracks', {'inputName': name, 'inputAudioTracks': {str(i): i == 1 for i in range(1, 7)}})
    ensure_filter(obs, overlay, 'limit peaks', 'limiter_filter', {'threshold': -1.0, 'release_time': 60})
    ensure_filter(obs, bed, 'duck under voices', 'compressor_filter', dict(DUCK, sidechain_source=overlay))
    return dict(music_file=music_file, music_db=MUSIC_DB, voice_lufs=-18, sidechain=overlay,
                game_audio=False, viewer_speech=False)
