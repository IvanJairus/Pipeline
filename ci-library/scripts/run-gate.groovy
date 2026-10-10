#!/usr/bin/env groovy
/*
  Titik masuk gate untuk sisi GitLab.

  Pipeline memanggil satu file ini, dan file ini hanya boleh mengatakan ya atau
  tidak atas dasar aturan yang sama persis dengan yang dipakai sisi Jenkins:
  ReleaseRules, GateResult dan DeploymentPlan dari shared-library/src. Tidak ada
  ambang yang diketik ulang di sini. Kalau sebuah angka tidak bisa ditunjuk ke
  salah satu dari tiga kelas itu, angka itu tidak boleh muncul di baris ini.

  Pemakaian:
    groovy -cp shared-library/src ci-library/scripts/run-gate.groovy \
      --manifest release.json --scan trivy-report.json \
      --quality sonar-gate.json --build build-info.json
    groovy -cp shared-library/src ci-library/scripts/run-gate.groovy --selftest

  Keluaran:
    gate-verdict.json  keputusan mesin, dibaca job berikutnya
    gate-summary.txt   satu baris yang ditempel ke ticket
  Kode keluar: 0 kalau lulus, 1 kalau ditolak. Stage gate memang harus merah.

  Format baris log mengikuti ci-library/scripts/lib/log.sh: waktu RFC3339 dengan
  offset, LEVEL, scope, pesan, lalu pasangan kunci=nilai. Dua implementasi, satu
  bentuk, supaya stream dari shell dan dari Groovy bisa dibaca sebagai satu log.
*/

import com.reference.release.ReleaseRules
import com.reference.release.GateResult
import com.reference.release.DeploymentPlan
import groovy.json.JsonSlurper
import groovy.json.JsonOutput
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

// ── log ─────────────────────────────────────────────────────────────────────
// Tanpa `def` di sini dengan sengaja: variabel skrip yang dideklarasikan dengan
// def bersifat lokal untuk run() dan tidak terlihat oleh method, jadi log() akan
// jatuh pada scope yang tidak ada. Binding bisa dilihat oleh keduanya.
scope = System.getenv('CI_JOB_NAME') ?: 'run-gate'
LOG_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSxxx")

void log(String level, String message) {
    def stamp = ZonedDateTime.now().format(LOG_FORMAT)
    System.err.println("${stamp} ${level} ${scope} ${message}")
}

// ── arg ─────────────────────────────────────────────────────────────────────
Map parseArgs(String[] argv) {
    def out = [:]
    for (int i = 0; i < argv.length; i++) {
        switch (argv[i]) {
            case '--manifest': out.manifest = argv[++i]; break
            case '--scan':     out.scan = argv[++i]; break
            case '--quality':  out.quality = argv[++i]; break
            case '--build':    out.build = argv[++i]; break
            case '--promote':  def pair = argv[++i].split(':'); out.from = pair[0]; out.to = pair[1]; break
            case '--no-environment': out.noEnvironment = true; break
            case '--artifact-only':  out.artifactOnly = true; break
            case '--selftest':       out.selftest = true; break
            default: throw new IllegalArgumentException("argumen tidak dikenal: ${argv[i]}")
        }
    }
    return out
}

Map readJson(String path, String label) {
    if (!path) return null
    def f = new File(path)
    if (!f.exists()) {
        // Berkas yang hilang BUKAN nol. Perbedaannya persis alasan kelas ini ada:
        // scanner yang tidak selesai akan terlihat seperti "tidak ada temuan".
        log('WARN', "read ${label} missing path=${path} treated=absent")
        return null
    }
    return new JsonSlurper().parse(f) as Map
}

/*
  Adaptor trivy-report.json -> bentuk yang dibaca GateResult.

  Kelas gate sengaja tidak tahu apa pun tentang Trivy: ia menerima daftar temuan.
  Terjemahannya hidup di sini, dan di sinilah kesalahan paling mahal di pipeline
  bisa terjadi - sebuah Results yang kosong karena scanner-nya mati akan
  menghasilkan daftar temuan kosong, yaitu "bersih". Karena itu `error` ikut
  dibawa, dan sbom diperiksa sebagai fakta terpisah, bukan disimpulkan dari
  jumlah temuan.
*/
Map toGateScan(Map trivy, boolean sbomProduced) {
    if (!trivy) return null
    def findings = []
    (trivy.Results ?: []).each { r ->
        (r.Vulnerabilities ?: []).each { v ->
            findings << [severity: v.Severity, id: v.VulnerabilityID, pkg: v.PkgName]
        }
    }
    return [findings: findings, sbom: sbomProduced, error: trivy.Error]
}

/*
  Adaptor sonar-gate.json -> bentuk yang dibaca GateResult.

  `null as Double` di Groovy adalah 0.0. Kalau konversi itu dipakai di sini,
  coverage yang tidak terukur berubah menjadi nol persen, dan gate menolak dengan
  alasan yang salah: "di bawah ambang", padahal yang terjadi adalah tidak ada
  angka. Yang benar adalah membiarkannya null supaya kelas gate bisa berkata
  "not measured".
*/
Map toGateQuality(Map sonar) {
    if (!sonar) return null
    def value = { String metric ->
        def c = sonar.conditions?.find { it.metricKey == metric }
        return c?.actualValue == null ? null : (c.actualValue as Double)
    }
    def status = sonar.projectStatus?.status
    return [
        status     : status == 'OK' ? 'passed' : (status ?: 'no status received'),
        coverage   : value('coverage'),
        duplication: value('duplicated_lines_density'),
    ]
}

// ── jalan ───────────────────────────────────────────────────────────────────
int run(Map opts) {
    log('INFO', "start manifest=${opts.manifest ?: 'none'} scan=${opts.scan ?: 'none'} quality=${opts.quality ?: 'none'}")

    def manifest = readJson(opts.manifest, 'manifest')
    def scan = readJson(opts.scan, 'scan')
    def quality = readJson(opts.quality, 'quality')
    def build = readJson(opts.build, 'build')

    def problems = []
    if (manifest) {
        def mp = ReleaseRules.validateManifest(manifest)
        mp.each { problems << "manifest: ${it}" }
        log(mp ? 'ERROR' : 'INFO', "validateManifest problems=${mp.size()}")
    } else {
        problems << 'manifest: release.json tidak dibaca, tidak ada yang bisa diverifikasi'
        log('ERROR', 'validateManifest skipped=missing-manifest')
    }

    if (opts.from && opts.to) {
        def pp = ReleaseRules.validatePromotion(opts.from, opts.to)
        pp.each { problems << "promotion: ${it}" }
        log(pp ? 'ERROR' : 'INFO', "validatePromotion ${opts.from}->${opts.to} problems=${pp.size()}")
    }

    // SBOM adalah fakta terpisah dari "tidak ada temuan": ia ada kalau berkasnya
    // ada dan tidak kosong, bukan kalau scanner-nya diam.
    def sbomFile = new File('sbom.json')
    boolean sbomProduced = sbomFile.exists() && sbomFile.length() > 2

    def gate = GateResult.evaluate([
        deploy : [result: build?.status ?: 'no result reported'],
        quality: toGateQuality(quality),
        scan   : toGateScan(scan, sbomProduced),
    ])
    log(gate.passed ? 'INFO' : 'ERROR', "GateResult.evaluate passed=${gate.passed} failures=${gate.failures.size()} warnings=${gate.warnings.size()}")

    def plan = []
    if (manifest && !opts.noEnvironment) {
        def envName = opts.to ?: (manifest.environments?.find()?.env ?: 'sit')
        plan = DeploymentPlan.build(manifest, envName)
        log('INFO', "DeploymentPlan.build env=${envName} services=${plan.size()} waves=${DeploymentPlan.waves(plan).size()}")
    }

    def verdict = [
        passed  : (boolean) (gate.passed && problems.isEmpty()),
        summary : problems.isEmpty() ? gate.summary : gate.summary + '; ' + problems.join('; '),
        failures: gate.failures + problems,
        warnings: gate.warnings,
        // `tier` di sini sudah hasil tierOf() dari build(). Memanggil tierOf lagi
        // pada baris ini bukan sekadar pemborosan: tierOf tidak idempoten, ia
        // melihat svc.tier yang sekarang berupa angka, tidak menemukannya di peta
        // TIER, dan mengembalikan gateway. Transkrip replay yang menangkap itu.
        plan    : plan.collect { [id: it.id, name: it.name, tier: it.tier, action: it.skip ? 'skipped' : 'deploy', watermark: it.watermark] },
        checkedAt: ZonedDateTime.now().format(LOG_FORMAT),
    ]

    new File('gate-verdict.json').text = JsonOutput.prettyPrint(JsonOutput.toJson(verdict)) + '\n'
    new File('gate-summary.txt').text = verdict.summary + '\n'
    log(verdict.passed ? 'INFO' : 'ERROR', "verdict written passed=${verdict.passed} file=gate-verdict.json")
    println verdict.summary
    return verdict.passed ? 0 : 1
}

// ── selftest ────────────────────────────────────────────────────────────────
/*
  Dijalankan tanpa runner, tanpa jaringan, tanpa berkas pipeline. Yang diuji
  adalah hal yang paling mudah rusak diam-diam: bentuk baris log, dan fakta
  bahwa input yang hilang menghasilkan penolakan, bukan kelulusan.
*/
int selftest() {
    int fails = 0
    // Parameternya sengaja tanpa tipe: hasil `=~` adalah Matcher, dan Groovy
    // tidak meng-coerce-nya ke boolean di batas closure yang bertipe.
    def check = { String name, ok ->
        if (!ok) { System.err.println("run-gate selftest FAIL ${name}"); fails++ }
    }

    def line = captureStderr { log('INFO', 'hello key=value') }
    check('bentuk baris log', line =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} INFO \S+ hello key=value$/)
    check('level salah ditolak', GateResult.evaluate(null).failures.size() == 1)

    def empty = GateResult.evaluate([:])
    check('input kosong ditolak', !empty.passed)

    def noScan = GateResult.evaluate([deploy: [result: 'success'], quality: [status: 'passed', coverage: 80, duplication: 2], scan: null])
    check('scan hilang ditolak', !noScan.passed && noScan.failures.any { it.contains('no report') })

    def ok = GateResult.evaluate([
        deploy : [result: 'success'],
        quality: [status: 'passed', coverage: 81.4, duplication: 3.1],
        scan   : [findings: [[severity: 'HIGH'], [severity: 'LOW']], sbom: true],
    ])
    check('input lengkap lulus', ok.passed)
    check('promotion mundur ditolak', ReleaseRules.validatePromotion('prod', 'sit').size() > 0)

    // Adaptor: dua jebakan yang membuat pipeline hijau padahal datanya tidak ada.
    def adapted = toGateScan([Results: [[Vulnerabilities: [[Severity: 'CRITICAL', VulnerabilityID: 'CVE-1', PkgName: 'jackson']]]]], true)
    check('trivy diadaptasi', adapted.findings.size() == 1 && adapted.findings[0].severity == 'CRITICAL')
    check('scanner mati bukan berarti bersih', toGateScan([Results: [], Error: 'timeout'], true).error == 'timeout')

    def noCoverage = toGateQuality([projectStatus: [status: 'OK'], conditions: []])
    check('coverage hilang tetap hilang', noCoverage.coverage == null)
    def gateNoCoverage = GateResult.evaluate([deploy: [result: 'success'], quality: noCoverage, scan: [findings: [], sbom: true]])
    check('ditolak karena tidak terukur', !gateNoCoverage.passed && gateNoCoverage.failures.any { it.contains('not measured') })
    // Yang tidak boleh muncul adalah angka yang dikarang: "0.0% below floor"
    // terdengar seperti tim gagal menulis test, padahal scanner-nya diam.
    check('tidak ada persentase yang dikarang', !gateNoCoverage.failures.any { it =~ /0(\.0)?%/ })

    System.err.println(fails == 0 ? 'run-gate selftest: ok' : "run-gate selftest: ${fails} kegagalan")
    return fails == 0 ? 0 : 1
}

String captureStderr(Closure c) {
    def saved = System.err
    def buf = new ByteArrayOutputStream()
    System.setErr(new PrintStream(buf, true, 'UTF-8'))
    try { c.call() } finally { System.setErr(saved) }
    return buf.toString('UTF-8').trim()
}

// ── main ────────────────────────────────────────────────────────────────────
def opts = parseArgs(args)
System.exit(opts.selftest ? selftest() : run(opts))
