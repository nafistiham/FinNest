from bhorosha_app_safety_check import integrity, schema as s


def test_demo_token_round_trip_and_tamper_detection():
    token = integrity.sign_demo_verdict("secret", ["KNOWN_INSTALLED", "UNKNOWN_CONTROLLING"], "POSSIBLE_RISK", request_hash="abc")
    verdict = integrity.resolve(token, demo_secret="secret", demo_allowed=True, package_name="com.bhorosha.app")
    assert verdict.source == "demo" and verdict.simulated
    assert verdict.apps_detected == ("KNOWN_INSTALLED", "UNKNOWN_CONTROLLING") and verdict.play_protect_verdict == "POSSIBLE_RISK" and verdict.request_hash == "abc"
    # a token that was offered but cannot be verified is "failed", not "none": an honest client never presents one
    assert integrity.resolve(token, demo_secret="other", demo_allowed=True, package_name="x").source == "failed"
    assert integrity.resolve(token, demo_secret="secret", demo_allowed=False, package_name="x").source == "failed"
    assert integrity.resolve(token[:-3] + "AAA", demo_secret="secret", demo_allowed=True, package_name="x").source == "failed"
    assert integrity.resolve(None, demo_secret="secret", demo_allowed=True, package_name="x").source == "none"
    assert integrity.resolve("opaque-google-token", demo_secret="secret", demo_allowed=True, package_name="x").source == "none"  # google path off by default
    assert verdict.app_recognition == "PLAY_RECOGNIZED" and verdict.device_recognition == ("MEETS_DEVICE_INTEGRITY",)


def test_demo_token_expires():
    token = integrity.sign_demo_verdict("secret", ["UNKNOWN_CONTROLLING"], now=1_000_000, ttl_s=60)
    assert integrity.verify_demo_token(token, "secret", now=1_000_030) is not None
    assert integrity.verify_demo_token(token, "secret", now=1_000_061) is None


def test_unknown_values_are_refused_when_signing_and_dropped_when_decoding():
    try:
        integrity.sign_demo_verdict("s", ["NOT_A_VALUE"])
    except ValueError:
        pass
    else:
        raise AssertionError
    payload = {"requestDetails": {"requestHash": "h"}, "environmentDetails": {"appAccessRiskVerdict": {"appsDetected": ["UNKNOWN_CAPTURING", "BOGUS"]}, "playProtectVerdict": "WHATEVER"}}
    verdict = integrity.from_decoded_payload(payload)
    assert verdict.source == "google" and not verdict.simulated
    assert verdict.apps_detected == ("UNKNOWN_CAPTURING",) and verdict.play_protect_verdict == "UNEVALUATED" and verdict.request_hash == "h"


def test_bundle_hash_is_order_independent_and_sensitive_to_content():
    from bhorosha_app_safety_check import schema as s

    a = s.AppRow("com.a", "A", "com.android.vending", permissions=("android.permission.CAMERA", "android.permission.INTERNET"))
    b = s.AppRow("com.b", "B", "com.android.chrome", has_accessibility_service=True)
    h1 = integrity.bundle_hash((a, b), s.DeviceRow())
    h2 = integrity.bundle_hash((b, a), s.DeviceRow())
    assert h1 == h2 and len(h1) == 64
    assert integrity.bundle_hash((a,), s.DeviceRow()) != h1
    assert integrity.bundle_hash((a, b), s.DeviceRow(rooted=True)) != h1


def test_attestation_levels():
    from bhorosha_app_safety_check import schema as s
    from bhorosha_app_safety_check.integrity import attestation_level

    h = "a" * 64
    def v(**kw):
        base = dict(source="demo", request_hash=h, app_recognition="PLAY_RECOGNIZED", device_recognition=("MEETS_DEVICE_INTEGRITY",), package_name="com.bhorosha.app")
        return s.IntegrityVerdict(**{**base, **kw})
    lvl = lambda verdict, expected=h: attestation_level(verdict, expected, expected_package="com.bhorosha.app")  # noqa: E731
    assert lvl(s.IntegrityVerdict(source="none")) == "none"
    assert lvl(s.IntegrityVerdict(source="failed")) == "failed"
    assert lvl(v(app_recognition="UNRECOGNIZED_VERSION")) == "tampered"  # a modded binary
    assert lvl(v(package_name="com.evil.bhorosha")) == "tampered"
    assert lvl(v(request_hash=None)) == "unbound"
    assert lvl(v(), expected="b" * 64) == "mismatch"  # token minted for another bundle
    assert lvl(v(device_recognition=("MEETS_STRONG_INTEGRITY", "MEETS_DEVICE_INTEGRITY", "MEETS_BASIC_INTEGRITY"))) == "strong"
    assert lvl(v()) == "device"
    assert lvl(v(device_recognition=("MEETS_BASIC_INTEGRITY",))) == "basic"
    assert lvl(v(device_recognition=("MEETS_VIRTUAL_INTEGRITY",))) == "virtual"
    assert attestation_level(v(certificate_digests=("sha-x",)), h, expected_package="com.bhorosha.app", expected_cert_digests=("sha-y",)) == "tampered"


def test_non_string_request_hash_is_a_mismatch_not_a_crash():
    """An int requestHash once reached hmac.compare_digest and raised TypeError out of the route."""
    from bhorosha_app_safety_check.integrity import attestation_level, from_decoded_payload

    forged = from_decoded_payload({"requestDetails": {"requestHash": 12345}, "appIntegrity": {"appRecognitionVerdict": "PLAY_RECOGNIZED", "packageName": "com.bhorosha.app"}, "deviceIntegrity": {"deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"]}})
    assert forged.request_hash == "12345"
    assert attestation_level(forged, "a" * 64, expected_package="com.bhorosha.app") == "mismatch"
    assert from_decoded_payload({"requestDetails": {"requestHash": ""}}).request_hash is None
    assert attestation_level(s.IntegrityVerdict(source="google", request_hash=7, app_recognition="PLAY_RECOGNIZED"), "a" * 64, expected_package="com.bhorosha.app") == "mismatch"  # type: ignore[arg-type]


def test_missing_certificate_digest_fails_a_configured_cert_check():
    """A token without certificateSha256Digest must not skip the check."""
    from bhorosha_app_safety_check.integrity import attestation_level, bundle_hash, resolve, sign_demo_verdict

    h = bundle_hash((), s.DeviceRow())
    bare = s.IntegrityVerdict(source="google", request_hash=h, app_recognition="PLAY_RECOGNIZED", device_recognition=("MEETS_DEVICE_INTEGRITY",))
    assert attestation_level(bare, h, expected_package="com.bhorosha.app", expected_cert_digests=("sha-y",)) == "tampered"
    assert attestation_level(bare, h, expected_package="com.bhorosha.app") == "device"  # nothing configured: not checked
    signed = sign_demo_verdict("k", [], request_hash=h, certificate_digests=["sha-y"])
    verdict = resolve(signed, demo_secret="k", demo_allowed=True, package_name="com.bhorosha.app")
    assert verdict.certificate_digests == ("sha-y",)
    assert attestation_level(verdict, h, expected_package="com.bhorosha.app", expected_cert_digests=("sha-y",)) == "device"


def test_demo_token_can_describe_a_modded_client_and_a_rooted_phone():
    modded = integrity.verify_demo_token(integrity.sign_demo_verdict("s", [], app_recognition="UNRECOGNIZED_VERSION"), "s")
    rooted = integrity.verify_demo_token(integrity.sign_demo_verdict("s", [], device_recognition=[]), "s")
    assert modded.app_recognition == "UNRECOGNIZED_VERSION" and rooted.device_recognition == ()


def test_bundle_hash_covers_the_2026_fields():
    from bhorosha_app_safety_check import schema as s
    a = s.AppRow("com.a", "A", "com.android.vending")
    base = integrity.bundle_hash((a,), s.DeviceRow())
    assert integrity.bundle_hash((s.AppRow("com.a", "A", "com.android.vending", has_hce_service=True),), s.DeviceRow()) != base
    assert integrity.bundle_hash((a,), s.DeviceRow(sdk_int=34)) != base
