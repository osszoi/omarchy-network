import QtQuick
import Quickshell
import Quickshell.Io
import "Logic.js" as Logic

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy-network"
  readonly property string configPath: configDir + "/config.json"
  readonly property string netrcPath: configDir + "/netrc"
  readonly property string stateDir: home + "/.local/state/omarchy-network"
  readonly property string vpnList: "omarchy-vpn-us"
  readonly property string vpnLabel: cfg && cfg.vpnLabel ? cfg.vpnLabel : "the VPN"
  readonly property string quarantineTag: "omarchy-network: quarantine"

  property var cfg: null
  property string configError: ""
  property var devices: []
  property var lanes: cfg ? cfg.lanes : []
  property string identity: ""
  property bool ready: false
  property bool reachable: false
  property bool refreshing: false
  property string lastError: ""
  property var busy: ({})
  property int unsortedCount: 0
  property int onlineCount: 0
  property bool watching: false

  property var health: ({})
  property var updates: ({})
  property bool quarantine: false
  property var history: ({})
  property var seen: null
  property var people: ({})
  property var presence: ({})
  property var pendingNotify: []
  property int tick: 0
  property var vendors: ({})
  property var vendorQueue: []
  property string vendorAsking: ""

  signal openRequested()
  signal actionFinished(string mac, bool ok, string message)

  // --- http queue, one curl at a time so the routers never see bursts

  property var queue: []
  property var current: null
  property int exitCode: -1
  property bool exited: false
  property bool outDone: false
  property bool errDone: false

  function request(method, path, body, done, base) {
    if (!cfg) { if (done) done(false, null, configError || "no config"); return }
    queue.push({ method: method, path: path, body: body, done: done, base: base || cfg.router })
    pump()
  }

  function pump() {
    if (current || queue.length === 0) return
    current = queue.shift()
    exited = false
    outDone = false
    errDone = false
    var argv = ["curl", "-sS", "-g", "-m", "8", "--max-filesize", "4000000", "--netrc-file", netrcPath, "-H", "Accept: application/json"]
    if (current.method !== "GET") {
      argv = argv.concat(["-X", current.method])
      if (current.body !== null && current.body !== undefined)
        argv = argv.concat(["-H", "Content-Type: application/json", "--data-binary", JSON.stringify(current.body)])
    }
    argv.push(current.base + "/rest/" + current.path)
    http.command = argv
    http.running = true
    watchdog.restart()
  }

  function finish() {
    if (!exited || !outDone || !errDone) return
    watchdog.stop()
    var job = current
    current = null
    var out = String(httpOut.text || "")
    var err = String(httpErr.text || "").trim()
    var data = null
    var ok = exitCode === 0
    if (ok) {
      try { data = out.trim() === "" ? [] : JSON.parse(out) } catch (e) { ok = false; err = "router sent something that isn't JSON" }
      if (ok && data && !Array.isArray(data) && data.error) {
        ok = false
        err = Logic.cleanText((data.detail || data.message || ("HTTP " + data.error)), 160)
        if (data.error === 401) err = "router login failed (check " + netrcPath + ")"
      }
    } else if (err === "") {
      err = "can't reach the router"
    }
    if (job && job.done) job.done(ok, data, Logic.cleanText(err, 200))
    pump()
  }

  Process {
    id: http
    stdout: StdioCollector {
      id: httpOut
      waitForEnd: true
      onStreamFinished: { root.outDone = true; root.finish() }
    }
    stderr: StdioCollector {
      id: httpErr
      waitForEnd: true
      onStreamFinished: { root.errDone = true; root.finish() }
    }
    onExited: function(code) {
      root.exitCode = code
      root.exited = true
      root.finish()
    }
  }

  Timer {
    id: watchdog
    interval: 12000
    onTriggered: {
      if (http.running) http.running = false
      root.exitCode = 28
      root.exited = true
      root.outDone = true
      root.errDone = true
      root.finish()
    }
  }

  // run a chain of GETs, stop at the first failure
  function getAll(paths, done, base) {
    var out = {}
    var keys = Object.keys(paths)
    var next = function(i) {
      if (i >= keys.length) { done(true, out, ""); return }
      request("GET", paths[keys[i]], null, function(ok, data, err) {
        if (!ok) { done(false, out, err); return }
        out[keys[i]] = data
        next(i + 1)
      }, base)
    }
    next(0)
  }

  // --- config + state files

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: { root.cfg = null; root.configError = "missing " + root.configPath + " (run install.sh)"; root.ready = true }
    onFileChanged: reload()
  }

  FileView {
    id: seenFile
    path: root.stateDir + "/seen.json"
    atomicWrites: true
    blockLoading: true
    printErrors: false
    onLoaded: {
      try { var s = JSON.parse(text()); root.seen = s && typeof s === "object" ? s : {} } catch (e) { root.seen = {} }
    }
    onLoadFailed: root.seen = null
  }

  FileView {
    id: peopleFile
    path: root.stateDir + "/people.json"
    atomicWrites: true
    blockLoading: true
    printErrors: false
    onLoaded: {
      var p = {}
      try {
        var s = JSON.parse(text())
        for (var k in s) if (Logic.isMac(k) && s[k] === true) p[k] = true
      } catch (e) {}
      root.people = p
    }
  }

  function loadConfig(text) {
    var parsed = Logic.parseConfig(text)
    if (parsed.error) { cfg = null; configError = parsed.error; ready = true; return }
    cfg = parsed
    configError = ""
    poll.interval = parsed.pollSeconds * 1000
    refresh()
  }

  function saveSeen() {
    var keys = Object.keys(seen || {})
    if (keys.length > 2000) {
      keys.sort(function(a, b) { return seen[a] - seen[b] })
      for (var i = 0; i < keys.length - 2000; i++) delete seen[keys[i]]
    }
    seenFile.setText(JSON.stringify(seen) + "\n")
  }

  // --- polling

  Timer {
    id: poll
    interval: 10000
    running: root.cfg !== null
    repeat: true
    onTriggered: root.refresh()
  }

  // faster bandwidth samples while the panel is open
  Timer {
    interval: 3000
    running: root.cfg !== null && root.watching
    repeat: true
    onTriggered: root.sampleRates()
  }

  function refresh() {
    if (!cfg || refreshing) return
    refreshing = true
    tick++
    var leasePath = "ip/dhcp-server/lease" + (cfg.dhcpServer ? "?server=" + encodeURIComponent(cfg.dhcpServer) : "")
    getAll({
      identity: "system/identity",
      leases: leasePath,
      regs: "interface/wifi/registration-table?.proplist=.id,interface,mac-address,band,signal,ssid",
      arps: "ip/arp?.proplist=mac-address,status",
      radios: "interface/wifi?.proplist=name,cap,master-interface,configuration.ssid",
      kids: "ip/kid-control",
      kidDevs: "ip/kid-control/device?.proplist=.id,mac-address,user,rate-down,rate-up",
      qrules: "interface/bridge/filter?.proplist=.id,comment,disabled"
    }, function(ok, bag, err) {
      if (!ok) { fail(err); return }
      bag.identity = bag.identity && bag.identity.name ? bag.identity.name : "router"
      apply(bag)
      if (tick % 3 === 1 || watching) refreshHealth()
    })
  }

  function fail(err) {
    refreshing = false
    reachable = false
    lastError = err
    ready = true
  }

  function apply(bag) {
    identity = Logic.cleanText(bag.identity, 32)
    var list = Logic.attachKids(Logic.buildDevices(bag, cfg), bag.kids, bag.kidDevs)
    for (var i = 0; i < list.length; i++) {
      var oui = list[i].mac.substring(0, 8).replace(/:/g, "")
      list[i].person = people[list[i].mac] === true
      list[i].vendor = list[i].randomMac ? "" : (vendors[oui] || "")
      list[i].guess = Logic.guessDevice(list[i], list[i].vendor)
      if (!list[i].randomMac && vendors[oui] === undefined && vendorQueue.indexOf(oui) === -1 && vendorAsking !== oui) vendorQueue.push(oui)
    }
    askVendor()
    devices = list
    unsortedCount = Logic.unsorted(list).length
    var online = 0
    for (var j = 0; j < list.length; j++) if (list[j].online) online++
    onlineCount = online
    var q = (bag.qrules || []).filter(function(r) { return r.comment === quarantineTag })
    quarantine = q.length > 0 && q.every(function(r) { return String(r.disabled) !== "true" })
    reachable = true
    lastError = ""
    ready = true
    refreshing = false
    pushHistory(list)
    checkNew(list)
    checkPresence(list)
    syncKidDevices(list)
  }

  // every device gets a kid-control entry so the router counts its traffic
  function syncKidDevices(list) {
    var missing = list.filter(function(d) { return !d.kidDeviceId })
    for (var i = 0; i < missing.length && i < 5; i++) {
      request("PUT", "ip/kid-control/device", { name: Logic.kidName(missing[i].mac), "mac-address": missing[i].mac, user: "omarchy-all" }, null)
    }
  }

  function pushHistory(list) {
    var h = {}
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      var prev = history[d.mac] || []
      var next = prev.concat([d.rateDown + d.rateUp])
      h[d.mac] = next.length > 40 ? next.slice(next.length - 40) : next
    }
    history = h
  }

  function sampleRates() {
    if (refreshing || current) return
    request("GET", "ip/kid-control/device?.proplist=mac-address,rate-down,rate-up", null, function(ok, rows) {
      if (!ok || !Array.isArray(rows)) return
      var byMac = {}
      for (var i = 0; i < rows.length; i++) byMac[String(rows[i]["mac-address"] || "").toUpperCase()] = rows[i]
      var list = devices.slice()
      for (var j = 0; j < list.length; j++) {
        var r = byMac[list[j].mac]
        if (!r) continue
        list[j] = Object.assign({}, list[j], { rateDown: Logic.parseRate(r["rate-down"]), rateUp: Logic.parseRate(r["rate-up"]) })
      }
      devices = list
      pushHistory(list)
    })
  }

  // --- health: main router + access points

  function refreshHealth() {
    getAll({
      resource: "system/resource?.proplist=uptime,version,cpu-load,board-name",
      temp: "system/health",
      pppoe: "interface?type=pppoe-out&.proplist=name,running,last-link-up-time,link-downs",
      addr: "ip/address?.proplist=address,interface,dynamic",
      watch: "tool/netwatch?.proplist=host,status,since,rtt-avg,comment"
    }, function(ok, bag) {
      if (!ok) return
      var h = {}
      var res = bag.resource || {}
      h.uptime = Logic.cleanText(res.uptime, 24)
      h.version = Logic.cleanText(res.version, 32)
      h.cpu = Number(res["cpu-load"]) || 0
      var t = (bag.temp || []).filter(function(x) { return x.name === "cpu-temperature" })[0]
      h.temp = t ? Number(t.value) : null
      var pp = (bag.pppoe || [])[0] || null
      h.wanUp = pp ? String(pp.running) === "true" : null
      h.wanSince = pp ? Logic.cleanText(pp["last-link-up-time"], 24) : ""
      h.wanName = pp ? Logic.cleanText(pp.name, 32) : ""
      var wan = (bag.addr || []).filter(function(a) { return pp && a.interface === pp.name })[0]
      h.publicIp = wan ? Logic.cleanText(String(wan.address).split("/")[0], 40) : ""
      var inet = (bag.watch || []).filter(function(w) { return w.comment === "internet" })[0]
      h.internetUp = inet ? inet.status === "up" : null
      h.latency = inet ? Logic.cleanText(inet["rtt-avg"], 16) : ""
      h.internetSince = inet ? Logic.cleanText(inet.since, 24) : ""
      health = h
    })
  }

  function loadOutages(done) {
    request("GET", "file?name=outages.0.txt&.proplist=contents", null, function(ok, rows, err) {
      if (!ok) { done([], err); return }
      var text = rows && rows[0] ? String(rows[0].contents || "") : ""
      var lines = text.split("\n").map(function(l) { return Logic.cleanText(l, 140) }).filter(function(l) { return l.indexOf("OUTAGE-LOG") !== -1 })
      done(lines.slice(Math.max(0, lines.length - 25)).reverse().map(function(l) { return l.replace(" script,error OUTAGE-LOG", "").replace(" script,warning OUTAGE-LOG", "") }), "")
    })
  }

  function routers() {
    return [{ name: identity || "router", url: cfg.router }].concat(cfg.aps)
  }

  function checkUpdates() {
    if (!cfg) return
    var list = routers()
    var u = {}
    var next = function(i) {
      if (i >= list.length) { updates = u; return }
      var r = list[i]
      request("POST", "system/package/update/check-for-updates", {}, function(okCheck, d0, errCheck) {
        request("GET", "system/package/update", null, function(ok, data) {
          var row = Array.isArray(data) ? data[0] : data
          var status = !okCheck ? (errCheck.indexOf("permission") !== -1 ? "checking needs the 'reboot' policy on the router user" : errCheck) : Logic.cleanText(row && row.status, 60)
          u[r.url] = ok && row ? {
            name: r.name,
            installed: Logic.cleanText(row["installed-version"], 24),
            latest: Logic.cleanText(row["latest-version"], 24),
            status: status
          } : { name: r.name, installed: "", latest: "", status: "can't check" }
          next(i + 1)
        }, r.url)
      }, r.url)
    }
    next(0)
  }

  // reboots that router; the panel asks first
  function installUpdate(url) {
    if (!cfg || !updates[url]) return
    request("POST", "system/package/update/install", {}, function(ok, d, err) {
      actionFinished("", ok, ok ? updates[url].name + " is updating and will reboot" : err)
    }, url)
  }

  // --- MAC vendor names from the system OUI list (hwdata)

  function askVendor() {
    if (vendorProc.running || vendorQueue.length === 0) return
    vendorAsking = vendorQueue.shift()
    if (!/^[0-9A-F]{6}$/.test(vendorAsking)) { askVendor(); return }
    vendorProc.command = ["grep", "-m1", "-E", "^" + vendorAsking + "[[:space:]]+\\(base 16\\)", "/usr/share/hwdata/oui.txt"]
    vendorProc.running = true
  }

  Process {
    id: vendorProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text).match(/\(base 16\)\s*(.+)/)
        var v = Object.assign({}, root.vendors)
        v[root.vendorAsking] = m ? Logic.cleanText(m[1], 40) : ""
        root.vendors = v
      }
    }
    onExited: Qt.callLater(root.askVendor)
  }

  // --- new device notifications

  function checkNew(list) {
    if (seen === null) {
      // first run ever: remember what's already here instead of flooding notifications
      seen = {}
      for (var i = 0; i < list.length; i++) seen[list[i].mac] = Date.now()
      saveSeen()
      return
    }
    var fresh = []
    for (var j = 0; j < list.length; j++) {
      var d = list[j]
      if (seen[d.mac]) continue
      seen[d.mac] = Date.now()
      if (!d.isStatic) fresh.push(d)
    }
    if (fresh.length === 0) return
    saveSeen()
    if (!cfg.notify) return
    var title = fresh.length === 1 ? "New device on the network" : fresh.length + " new devices on the network"
    var body = fresh.slice(0, 4).map(function(x) { return x.name + " · " + x.ip }).join("\n") + (fresh.length > 4 ? "\n…" : "")
    notify(title, body, true)
  }

  // --- who's home: arrivals/departures of the phones you mark

  function checkPresence(list) {
    var now = Date.now()
    var awayMs = cfg.awayMinutes * 60000
    var next = {}
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      if (!d.person) continue
      var r = Logic.presenceStep(presence[d.mac] || null, !!d.wifi, now, awayMs)
      next[d.mac] = r.state
      if (presence[d.mac] && r.event === "arrived") notify(d.name + " is home", "Joined " + (d.wifi ? d.wifi.ap : "the WiFi"), false)
      else if (presence[d.mac] && r.event === "left") notify(d.name + " left", "Off the WiFi for " + cfg.awayMinutes + " min", false)
    }
    presence = next
  }

  function setPerson(mac, on) {
    var p = Object.assign({}, people)
    if (on) p[mac] = true
    else delete p[mac]
    people = p
    peopleFile.setText(JSON.stringify(p) + "\n")
    var list = devices.slice()
    for (var i = 0; i < list.length; i++) if (list[i].mac === mac) list[i] = Object.assign({}, list[i], { person: on })
    devices = list
    actionFinished(mac, true, on ? "You'll get a notification when it comes and goes" : "No more arrival notifications")
  }

  function notify(title, body, openable) {
    pendingNotify = pendingNotify.concat([{ title: title, body: body, openable: openable }])
    sendNotify()
  }

  function sendNotify() {
    if (notifier.running || pendingNotify.length === 0) return
    var n = pendingNotify[0]
    pendingNotify = pendingNotify.slice(1)
    var argv = ["notify-send", "-a", "Home network", "-i", "network-wired"]
    if (n.openable) argv = argv.concat(["-A", "default=Sort it"])
    notifier.command = argv.concat([n.title, n.body])
    notifier.running = true
  }

  Process {
    id: notifier
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text).trim() === "default") root.openRequested()
      }
    }
    onExited: Qt.callLater(root.sendNotify)
  }

  // --- actions

  function deviceByMac(mac) {
    for (var i = 0; i < devices.length; i++) if (devices[i].mac === mac) return devices[i]
    return null
  }

  function setBusy(mac, value) {
    var b = Object.assign({}, busy)
    if (value) b[mac] = value
    else delete b[mac]
    busy = b
  }

  function done(mac, ok, message) {
    setBusy(mac, "")
    actionFinished(mac, ok, message || "")
    refreshing = false
    refresh()
  }

  // dynamic leases have to become static before they keep a name, address or list
  function ensureStatic(dev, next) {
    if (dev.isStatic) { next(dev.leaseId); return }
    request("POST", "ip/dhcp-server/lease/make-static", { ".id": dev.leaseId }, function(ok, data, err) {
      if (!ok) { done(dev.mac, false, err); return }
      var q = "ip/dhcp-server/lease?mac-address=" + encodeURIComponent(dev.mac) + (cfg.dhcpServer ? "&server=" + encodeURIComponent(cfg.dhcpServer) : "")
      request("GET", q, null, function(ok2, rows, err2) {
        if (!ok2) { done(dev.mac, false, err2); return }
        var id = ""
        for (var i = 0; i < (rows || []).length; i++) if (String(rows[i].dynamic) !== "true") id = String(rows[i][".id"])
        if (!id) { done(dev.mac, false, "the lease didn't become static"); return }
        next(id)
      })
    })
  }

  function kick(dev, next) {
    if (!cfg.kickWifi || !dev.wifi || !dev.wifi.regId) { next(); return }
    request("POST", "interface/wifi/registration-table/remove", { ".id": dev.wifi.regId }, function() { next() })
  }

  // drop the device's tracked connections so a new rule applies right away
  function flush(ip, next) {
    if (!Logic.isIPv4(ip)) { next(); return }
    request("POST", "execute", { script: ":foreach c in=[/ip firewall connection find where src-address=" + ip + "] do={/ip firewall connection remove $c}" }, function() { next() })
  }

  function assign(mac, laneId, ip, name) {
    var dev = deviceByMac(mac)
    if (!dev || busy[mac]) return "busy"
    var clean = Logic.cleanName(name)
    if (!clean) return "Give it a name"
    var problem = Logic.validateAssign(ip, laneId, mac, devices, cfg)
    if (problem) return problem
    setBusy(mac, "moving")
    ensureStatic(dev, function(id) {
      request("PATCH", "ip/dhcp-server/lease/" + id, { address: ip, comment: clean }, function(ok, data, err) {
        if (!ok) { done(mac, false, err); return }
        if (ip === dev.activeIp) { done(mac, true, clean + " keeps " + ip); return }
        kick(dev, function() { done(mac, true, clean + " → " + ip + (dev.wifi ? " · it switches when it reconnects or renews (iPhones: up to 15 min)" : " · it switches at its next renewal (up to 15 min)")) })
      })
    })
    return ""
  }

  function rename(mac, name) {
    var dev = deviceByMac(mac)
    if (!dev || busy[mac]) return "busy"
    var clean = Logic.cleanName(name)
    if (!clean) return "Give it a name"
    setBusy(mac, "saving")
    ensureStatic(dev, function(id) {
      request("PATCH", "ip/dhcp-server/lease/" + id, { comment: clean }, function(ok, data, err) {
        done(mac, ok, ok ? "Renamed to " + clean : err)
      })
    })
    return ""
  }

  function forget(mac) {
    var dev = deviceByMac(mac)
    if (!dev || busy[mac] || !dev.isStatic) return "busy"
    setBusy(mac, "forgetting")
    request("DELETE", "ip/dhcp-server/lease/" + dev.leaseId, null, function(ok, data, err) {
      if (!ok) { done(mac, false, err); return }
      kick(dev, function() { done(mac, true, dev.name + " goes back to New") })
    })
    return ""
  }

  // pause/bedtime need the device in its own kid-control profile
  function ensureKid(dev, next) {
    if (dev.kidId) { next(dev.kidId); return }
    var name = Logic.kidName(dev.mac)
    var all = { mon: "0s-1d", tue: "0s-1d", wed: "0s-1d", thu: "0s-1d", fri: "0s-1d", sat: "0s-1d", sun: "0s-1d" }
    request("GET", "ip/kid-control?name=" + name, null, function(ok, rows, err) {
      if (!ok) { done(dev.mac, false, err); return }
      var attach = function(kidId) {
        var body = { name: name, "mac-address": dev.mac, user: name }
        var cb = function(ok2, d2, err2) { if (!ok2) { done(dev.mac, false, err2); return } next(kidId) }
        if (dev.kidDeviceId) request("PATCH", "ip/kid-control/device/" + dev.kidDeviceId, { user: name }, cb)
        else request("PUT", "ip/kid-control/device", body, cb)
      }
      if (rows && rows.length) { attach(String(rows[0][".id"])); return }
      request("PUT", "ip/kid-control", Object.assign({ name: name }, all), function(ok3, kid, err3) {
        if (!ok3 || !kid || !kid[".id"]) { done(dev.mac, false, err3 || "couldn't create the profile"); return }
        attach(String(kid[".id"]))
      })
    })
  }

  function setPaused(mac, paused) {
    var dev = deviceByMac(mac)
    if (!dev || busy[mac]) return "busy"
    setBusy(mac, paused ? "pausing" : "resuming")
    ensureKid(dev, function(kidId) {
      request("POST", "ip/kid-control/" + (paused ? "pause" : "resume"), { ".id": kidId }, function(ok, d, err) {
        if (!ok) { done(mac, false, err); return }
        if (!paused) { done(mac, true, dev.name + " is back online"); return }
        flush(dev.activeIp || dev.ip, function() { done(mac, true, dev.name + "'s internet is paused") })
      })
    })
    return ""
  }

  function setBedtime(mac, enabled, from, to) {
    var dev = deviceByMac(mac)
    if (!dev || busy[mac]) return "busy"
    var win = "0s-1d"
    if (enabled) {
      var b = Logic.bedtimeWindow(from, to)
      if (b.error) return b.error
      win = b.window
    }
    setBusy(mac, "saving")
    ensureKid(dev, function(kidId) {
      request("PATCH", "ip/kid-control/" + kidId, { mon: win, tue: win, wed: win, thu: win, fri: win, sat: win, sun: win }, function(ok, d, err) {
        done(mac, ok, ok ? (enabled ? dev.name + ": no internet " + from + " → " + to : dev.name + ": bedtime off") : err)
      })
    })
    return ""
  }

  function setVpn(mac, on) {
    var dev = deviceByMac(mac)
    if (!dev || busy[mac]) return "busy"
    setBusy(mac, on ? "routing via US" : "routing home")
    ensureStatic(dev, function(id) {
      var lists = dev.addressLists ? dev.addressLists.split(",").filter(function(x) { return x && x !== vpnList }) : []
      if (on) lists.push(vpnList)
      request("PATCH", "ip/dhcp-server/lease/" + id, { "address-lists": lists.join(",") }, function(ok, d, err) {
        if (!ok) { done(mac, false, err); return }
        flush(dev.activeIp || dev.ip, function() { done(mac, true, on ? dev.name + " now goes out through " + vpnLabel : dev.name + " goes out from home again") })
      })
    })
    return ""
  }

  function setQuarantine(on) {
    if (!cfg) return
    var list = routers()
    var failed = ""
    var next = function(i) {
      if (i >= list.length) {
        actionFinished("", failed === "", failed === "" ? (on ? "Quarantine on: new devices get internet only" : "Quarantine off") : failed)
        refreshing = false
        refresh()
        return
      }
      var r = list[i]
      request("GET", "interface/bridge/filter?.proplist=.id,comment", null, function(ok, rows, err) {
        if (!ok) { failed = r.name + ": " + err; next(i + 1); return }
        var ids = (rows || []).filter(function(x) { return x.comment === quarantineTag }).map(function(x) { return x[".id"] })
        if (ids.length === 0) { failed = r.name + " has no quarantine rules"; next(i + 1); return }
        var each = function(k) {
          if (k >= ids.length) { next(i + 1); return }
          request("PATCH", "interface/bridge/filter/" + ids[k], { disabled: on ? "false" : "true" }, function(ok2, d, err2) {
            if (!ok2) failed = r.name + ": " + err2
            each(k + 1)
          }, r.url)
        }
        each(0)
      }, r.url)
    }
    next(0)
  }

  function loadLookups(mac, done) {
    var dev = deviceByMac(mac)
    if (!dev) { done([], ""); return }
    request("GET", "log?buffer=omarchydns&.proplist=time,message", null, function(ok, rows, err) {
      done(ok ? Logic.parseLookups(rows, dev.activeIp || dev.ip, 40) : [], ok ? "" : err)
    })
  }

  function suggestIp(mac, laneId) {
    if (!cfg) return ""
    var dev = deviceByMac(mac)
    if (dev && dev.lane === laneId && dev.isStatic) return dev.ip
    return Logic.nextFreeIp(laneId, devices, cfg, mac)
  }

  function check(mac, laneId, ip) {
    return cfg ? Logic.validateAssign(ip, laneId, mac, devices, cfg) : "no config"
  }

  Component.onCompleted: configFile.reload()
}
