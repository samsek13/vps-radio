#!/usr/bin/env python3
"""
test_spotify_helper.py — Unit test for spotify-helper
"""
import os
import sys
import json
import time
import unittest
from unittest.mock import patch, MagicMock
import urllib.error
import importlib.util

# 动态加载 spotify-helper 模块 (无 .py 后缀)
from importlib.machinery import SourceFileLoader

helper_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "spotify-helper"))
loader = SourceFileLoader("spotify_helper", helper_path)
sp = loader.load_module()


class TestSpotifyHelper(unittest.TestCase):
    def setUp(self):
        self.test_cfg_path = os.path.abspath(f"test_spotify_auth_{os.getpid()}.json")
        sp.CONFIG_PATH = self.test_cfg_path

    def tearDown(self):
        if os.path.exists(self.test_cfg_path):
            os.remove(self.test_cfg_path)

    def test_save_and_load_config(self):
        sample = {
            "client_id": "test_cid",
            "client_secret": "test_sec",
            "refresh_token": "test_ref",
            "access_token": "test_acc",
            "expires_at": int(time.time()) + 3600
        }
        sp.save_config(sample)
        loaded = sp.load_config()
        self.assertEqual(loaded["client_id"], "test_cid")
        self.assertEqual(loaded["access_token"], "test_acc")

    def test_get_access_token_cached(self):
        sample = {
            "client_id": "cid",
            "client_secret": "sec",
            "refresh_token": "ref",
            "access_token": "cached_valid_token",
            "expires_at": int(time.time()) + 1000
        }
        sp.save_config(sample)
        token = sp.get_access_token(force_refresh=False)
        self.assertEqual(token, "cached_valid_token")

    @patch("urllib.request.urlopen")
    def test_token_auto_refresh(self, mock_urlopen):
        sample = {
            "client_id": "cid",
            "client_secret": "sec",
            "refresh_token": "ref",
            "access_token": "old_token",
            "expires_at": int(time.time()) - 100 # expired
        }
        sp.save_config(sample)

        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({
            "access_token": "fresh_new_token",
            "expires_in": 3600
        }).encode("utf-8")
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        token = sp.get_access_token()
        self.assertEqual(token, "fresh_new_token")

        # 检查是否回写配置文件
        cfg = sp.load_config()
        self.assertEqual(cfg["access_token"], "fresh_new_token")
        self.assertGreater(cfg["expires_at"], time.time())

    @patch("urllib.request.urlopen")
    def test_call_spotify_api_204_success(self, mock_urlopen):
        sample = {
            "client_id": "cid",
            "client_secret": "sec",
            "refresh_token": "ref",
            "access_token": "valid_token",
            "expires_at": int(time.time()) + 3600
        }
        sp.save_config(sample)

        mock_resp = MagicMock()
        mock_resp.status = 204
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        res = sp.call_spotify_api("POST", "/me/player/next")
        self.assertEqual(res, {})

    @patch("urllib.request.urlopen")
    def test_call_spotify_api_404_device_not_found(self, mock_urlopen):
        sample = {
            "client_id": "cid",
            "client_secret": "sec",
            "refresh_token": "ref",
            "access_token": "valid_token",
            "expires_at": int(time.time()) + 3600
        }
        sp.save_config(sample)

        err_fp = MagicMock()
        err_fp.read.return_value = json.dumps({"error": {"message": "NO_ACTIVE_DEVICE"}}).encode("utf-8")
        http_err = urllib.error.HTTPError("https://api.spotify.com/v1/me/player/next", 404, "Not Found", {}, err_fp)
        mock_urlopen.side_effect = http_err

        with self.assertRaises(SystemExit) as cm:
            sp.call_spotify_api("POST", "/me/player/next")
        self.assertEqual(cm.exception.code, 22)

    @patch("urllib.request.urlopen")
    def test_call_spotify_api_401_retry_success(self, mock_urlopen):
        sample = {
            "client_id": "cid",
            "client_secret": "sec",
            "refresh_token": "ref",
            "access_token": "expired_token",
            "expires_at": int(time.time()) + 3600
        }
        sp.save_config(sample)

        # 模拟第 1 次 401，第 2 次 refresh_token 成功返回，第 3 次 API 请求 204
        err_fp = MagicMock()
        err_fp.read.return_value = json.dumps({"error": {"message": "The access token expired"}}).encode("utf-8")
        err_401 = urllib.error.HTTPError("https://api.spotify.com/v1/me/player/next", 401, "Unauthorized", {}, err_fp)

        mock_refresh_resp = MagicMock()
        mock_refresh_resp.read.return_value = json.dumps({
            "access_token": "new_refreshed_token",
            "expires_in": 3600
        }).encode("utf-8")

        mock_ok_resp = MagicMock()
        mock_ok_resp.status = 204

        mock_urlopen.side_effect = [
            err_401,
            MagicMock(__enter__=MagicMock(return_value=mock_refresh_resp)),
            MagicMock(__enter__=MagicMock(return_value=mock_ok_resp)),
        ]

        res = sp.call_spotify_api("POST", "/me/player/next")
        self.assertEqual(res, {})
        cfg = sp.load_config()
        self.assertEqual(cfg["access_token"], "new_refreshed_token")

    @patch("urllib.request.urlopen")
    def test_cmd_auth_set(self, mock_urlopen):
        mock_refresh_resp = MagicMock()
        mock_refresh_resp.read.return_value = json.dumps({
            "access_token": "initial_access_token",
            "expires_in": 3600
        }).encode("utf-8")
        mock_urlopen.return_value.__enter__.return_value = mock_refresh_resp

        with self.assertRaises(SystemExit) as cm:
            sp.cmd_auth_set("my_cid", "my_csec", "my_refresh")
        self.assertEqual(cm.exception.code, 0)

        cfg = sp.load_config()
        self.assertEqual(cfg["client_id"], "my_cid")
        self.assertEqual(cfg["client_secret"], "my_csec")
        self.assertEqual(cfg["refresh_token"], "my_refresh")
        self.assertEqual(cfg["access_token"], "initial_access_token")


if __name__ == "__main__":
    unittest.main()
