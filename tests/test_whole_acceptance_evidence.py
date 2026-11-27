"""Exercise the complete offline verifier with explicitly synthetic evidence.

Never publish these fixtures as device evidence. This is a verifier regression,
not a 168-hour run or a physical traffic measurement.
"""
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/acceptance"))
import unattended as qa
import run_all as runner
import verify_report as verifier
import diagnostics


SHA = "a" * 40
WALL = 1_800_000_000


def encode(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


def log(root, name, raw):
    path = root / "logs" / (name + ".log")
    path.write_bytes(raw)
    path.chmod(0o600)
    return runner.row(name, "pass", "exit", log="logs/" + path.name,
                      log_sha256=hashlib.sha256(raw).hexdigest(),
                      exit_code=0, duration_seconds=1)


def make_automatic(out):
    out.mkdir(mode=0o700)
    (out / "logs").mkdir(mode=0o700)
    env = {"os":"Darwin", "os_version":"15.0", "architecture":"arm64",
           "python":"3.12", "hardware_model":"Mac16,12"}
    options = {"performance":False,"traffic":False}
    plan = runner.planned_steps("host", **options)
    rows = [runner.row("preflight", "pass", "clean_macos_checkout")]
    timing = {name: {"construction_ms":1, "layout_ms":2} for name in (
        "Smoke · Quick panel","Smoke · Settings","Smoke · Management","Smoke · History")}
    for name in plan[1:]:
        raw = (verifier.MARKERS.get(name, "synthetic") + "\n").encode()
        if name == "coverage":
            raw = encode({"executable_lines":100,"covered_lines":95,
                          "complete_inventory":True,"meets_target":True})
        if name.endswith("_smoke"):
            raw += b"NETGUARD_FIXTURE_TIMING " + encode(timing) + b"\n"
        rows.append(log(out, name, raw))
    report = {"schema_version":2,"kind":"local_automatic","started_at":runner.now(),
        "finished_at":runner.now(),"commit_sha":SHA,"clean_at_start":True,
        "clean_at_end":True,"same_revision_at_end":True,"environment":env,
        "profile":"host","options":options,"planned_steps":list(plan),"steps":rows,
        "manual_gates":[{"id":id,"status":"blocked" if id in runner.BLOCKED_IDS else "review_required"}
                        for id in runner.MANUAL_IDS],"full_device_acceptance":False,"automatic_exit_code":0}
    runner.write_json(out / "environment.json", env)
    runner.write_json(out / "summary.json", report)
    return verifier.verify(out, SHA)


def heartbeat(t):
    day = (dt.date(2026,11,20) + dt.timedelta(days=t//86400)).isoformat()
    return dict(schema_version=1, wall_seconds=WALL+t, tick_count=t+100,
                sample_cycles=t+100, measured_cycles=t+99, save_successes=t//10+10,
                max_tick_gap_seconds=1.1, max_tick_duration_seconds=.02,
                max_sample_age_seconds=.03, max_save_gap_seconds=10,
                safety_hold_ticks=0, visible_ticks=0, ui_visible=False, sample_age_seconds=.01, save_age_seconds=1,
                day=day, received=(t%86400)*10, sent=(t%86400)*2,
                sleeping=False, clock_held=False, persistence_blocked=False,
                accounting_overflow=False, history_healthy=True,
                busy_seconds=dict.fromkeys(("route","apps","ping","provider","dns"),0),
                max_busy_seconds=dict.fromkeys(("route","apps","ping","provider","dns"),0))


def observation(out, name, seconds, interval, offset=0):
    rows = []
    resource_keys = {"open_descriptors", "thread_rows", "descendant_count",
                     "descendant_rss_bytes", "zombie_descendants", "matching_diagnostic_reports",
                     *diagnostics.RUSAGE_KEYS}
    for t in range(0, seconds+1, interval):
        h = heartbeat(t)
        h["wall_seconds"] += offset
        row = {"elapsed_seconds":t,"wall_elapsed_seconds":t,"sample_wall_seconds":WALL+t+offset,
               "cpu_seconds_delta":t*.002,"rss_bytes":50_000_000,"health":h}
        if interval == qa.SOAK_INTERVAL:
            if t % 300 == 0:
                row["resources"] = dict.fromkeys(resource_keys,0)
                row["resources"].update(open_descriptors=5,thread_rows=4,physical_footprint_bytes=40_000_000,
                                        disk_read_bytes=t,disk_write_bytes=t)
            if t % 3600 == 0:
                row["persisted_state"] = dict(day=h["day"], received=h["received"], sent=h["sent"],
                    total=h["received"]+h["sent"], measured_samples=t%86400)
                history = {"status":"snapshot_validated","days":{},"database_bytes":8192}
                row["history"] = history
                if t > 0 and t % 86400 == 0:
                    before = rows[-1]["health"]
                    history["days"][before["day"]] = {"received":before["received"],"sent":before["sent"]}
                    row["rollover"] = "observed_lower_bound_met_review_required"
        rows.append(row)
    raw = b"".join(encode(row)+b"\n" for row in rows)
    if len(raw) > runner.LIMIT:
        raise AssertionError("fixture exceeds real log limit")
    path = out / (name + ".jsonl")
    path.write_bytes(raw)
    path.chmod(0o600)
    summary = dict(samples=len(rows),elapsed_seconds=seconds,max_gap_seconds=interval,
                   requested_seconds=seconds,interval_seconds=interval,max_rss_bytes=50_000_000,
                   sha256=hashlib.sha256(raw).hexdigest())
    if interval == 5:
        summary.update(status="numeric_target_met_review_required",
                       metrics=dict(meets_observation_window=True, meets_numeric_target=True,
                                    cpu_percent_one_core=.2,max_rss_bytes=50_000_000))
    else:
        summary["status"] = "duration_met_review_required"
    runner.write_json(out / (name + ".json"),summary)
    return qa.observation_evidence(out,name,seconds,interval,require_health=True)


class WholeAcceptanceEvidenceTests(unittest.TestCase):
    def test_full_plan_and_adversarial_evidence(self):
        with tempfile.TemporaryDirectory(prefix="synthetic-qa-") as folder:
            out = Path(folder)
            (out / "logs").mkdir(mode=0o700)
            auto = make_automatic(out / "automatic")
            preflight = {"kind":"isolated_preflight","full_device_acceptance":False,
                         "scope":"loopback_payload_and_fixture_only_not_physical_accounting",
                         "heartbeat":{v:{"status":"producer_consumer_fixture_verified","ticks":4,
                             "recovered_hold_rejected":True,"existing_report_preserved":True}
                             for v in ("legacy","module")},
                         "loopback":{k:{"status":"payload_roundtrip_verified","bytes_each_direction":8192,
                             "sha256":hashlib.sha256(bytes(range(256))*32).hexdigest()}
                             for k in ("ipv4_tcp","ipv4_udp","ipv6_tcp","ipv6_udp")}}
            steps = {name:log(out,name,(marker+"\n").encode()) for name,marker in qa.ISOLATED_MARKERS.items()}
            steps["qa_preflight"] = log(out,"qa_preflight",encode(preflight)+b"\n"+
                                       qa.ISOLATED_MARKERS["qa_preflight"].encode()+b"\n")
            cycles = []
            for i in range(28):
                cycles.append({"index":i,"started_elapsed_seconds":i*qa.REGRESSION_PERIOD,
                    "steps":[log(out,"regression_%02d_%s"%(i,suffix),b"synthetic test only\n")
                             for suffix in ("python","swift")]})
            runner.write_json(out / "regressions.json",cycles)
            observations = {"idle_"+str(i+1):observation(out,"idle_"+str(i+1),300,5,i*301)
                            for i in range(3)}
            observations["soak"] = observation(out,"soak",qa.TARGET,qa.SOAK_INTERVAL,903)
            report = {"schema_version":3,"kind":"unattended_acceptance","commit_sha":SHA,
                "started_at":dt.datetime.fromtimestamp(WALL-1,dt.timezone.utc).isoformat(),
                "finished_at":dt.datetime.fromtimestamp(WALL+qa.TARGET+904,dt.timezone.utc).isoformat(),
                "full_device_acceptance":False,"release_authorized":False,
                "status":"observations_complete_review_required","automatic":auto,
                "fixture_ui_timing":qa.fixture_timing(out),"qa_preflight":preflight,
                "steps":steps,"manual_gates":report_gates(),
                "candidate_inventory":{"schema_version":1,"kind":"candidate_content_inventory","commit_sha":SHA,
                   "provenance":"content_identity_only_not_signed","release_authorized":False,
                   "full_device_acceptance":False,"bundles":{v:{"sha256":"b"*64,"bundle_short_version":"3.0",
                       "bundle_build_version":None} for v in ("legacy","module")}},
                "matched_candidate_variants":["legacy"],"soak_requested_seconds":qa.TARGET,
                "observations":observations,"evidence_gaps":qa.evidence_gaps(observations,auto,preflight)}
            runner.write_json(out / "summary.json", report)
            result = qa.review_completed(out,SHA)
            self.assertEqual(result["status"],"observations_complete_review_required")
            self.assertFalse(result["full_device_acceptance"])
            self.assertEqual(result["observations"]["soak"]["samples"],10081)
            self.assertEqual(result["observations"]["soak"]["periodic_regressions"]["cycles"],28)
            self.assertIn("normal_mode_idle_performance",result["evidence_gaps"])
            with self.assertRaises(ValueError):
                qa.review_completed(out,"b"*40)
            report["evidence_gaps"] = []
            runner.write_json(out / "summary.json",report)
            with self.assertRaises(ValueError):
                qa.review_completed(out,SHA)
            report["evidence_gaps"] = qa.evidence_gaps(observations,auto,preflight)
            runner.write_json(out / "summary.json",report)
            runner.write_json(out / "regressions.json",cycles[:-1])
            with self.assertRaises(ValueError):
                qa.review_completed(out,SHA)
            runner.write_json(out / "regressions.json",cycles)
            path = out / "logs/regression_00_swift.log"
            path.write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                qa.review_completed(out,SHA)


def report_gates():
    return [{"id":id,"status":"blocked" if id in runner.BLOCKED_IDS else "review_required"}
            for id in runner.MANUAL_IDS]
