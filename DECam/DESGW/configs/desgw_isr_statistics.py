"""IsrStatisticsTask subclass that backfills MJD for DECam.

lsst.ip.isr.isrStatistics.IsrStatisticsTask.run() unconditionally reads
inputExp.getMetadata().get("MJD", None) (isrStatistics.py) with no config
override for the keyword name. DECam raw headers carry the date as MJD-OBS,
never as a literal "MJD" key, so this is always None for DECam -- which
crashes every cp_verify Det-stage quantum (verifyBiasDet/verifyFlatDet)
trying to serialize an all-None "mjd" column to Parquet. See
desgw_verify_bias.yaml / desgw_verify_flat.yaml for the full story.

This has to be a real, importable module -- not a pipeline `python:` config
block that monkeypatches IsrStatisticsTask.run() in place. pipetask
multiprocessing always uses the `spawn` start method (fork is no longer
supported: `pipetask run --help` says so explicitly), so a monkeypatch
applied by a `python:` block only takes effect in the process that builds
the quantum graph; every spawned worker process is a fresh interpreter that
reconstructs its Config from pickled field *values* only -- it never
replays the arbitrary code that produced them, so the patched module-level
method is simply absent there. A retargeted subtask class defined in a real
module gets re-imported by each worker like any other class, which does
survive spawning -- but only if this module's directory is on that worker's
PYTHONPATH too (the verify-*.sh scripts export it explicitly).
"""

from lsst.ip.isr.isrStatistics import IsrStatisticsTask

__all__ = ["DesgwIsrStatisticsTask"]


class DesgwIsrStatisticsTask(IsrStatisticsTask):
    def run(self, inputExp, *args, **kwargs):
        result = super().run(inputExp, *args, **kwargs)
        if result.results.get("MJD") is None:
            md = inputExp.getMetadata()
            if "MJD-OBS" in md:
                result.results["MJD"] = md["MJD-OBS"]
        return result
