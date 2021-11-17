//
// Copyright (c) 2021, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   18 Oct 2021  Matthew Giannini  Creation
//

using concurrent
using inet
using util
using haystack
using hx

**
** PyMgr
**
internal const class PyMgr : Actor
{

//////////////////////////////////////////////////////////////////////////
// Constructor
//////////////////////////////////////////////////////////////////////////

  new make(PyLib lib, |This|? f := null) : super(lib.rt.libs.actorPool)
  {
    f?.call(this)
    this.lib = lib
  }

  internal const PyLib lib
  private Log log() { lib.log }
  private const ConcurrentMap sessions := ConcurrentMap()
  private const AtomicBool running := AtomicBool(true)

  private static const Duration timeout := 10sec

  private PyDockerSession? lookup(Str id) { ((Unsafe?)sessions.get(id))?.val }

//////////////////////////////////////////////////////////////////////////
// PyMgr
//////////////////////////////////////////////////////////////////////////

  PySession openSession(Dict? opts := null)
  {
    taskSession(opts) ?: createSession(opts)
  }

  Void shutdown(Duration? timeout := PyMgr.timeout)
  {
    send(HxMsg("shutdown")).get(timeout)
  }

  internal PyMgrSession? taskSession(Dict? opts := null)
  {
    try
    {
      tasks := (HxTaskService?)lib.rt.services.get(HxTaskService#)
      return tasks.adjunct |->HxTaskAdjunct| { createSession(opts) }
    }
    catch (Err err)
    {
      return null
    }
  }

  private PyMgrSession createSession(Dict? opts)
  {
    send(HxMsg("open", PyMgrSession(this, opts ?: Etc.emptyDict).open)).get(timeout)
  }

//////////////////////////////////////////////////////////////////////////
// Actor
//////////////////////////////////////////////////////////////////////////

  protected override Obj? receive(Obj? obj)
  {
    msg := (HxMsg)obj
    switch (msg.id)
    {
      case "open":     return onOpen(msg.a)
      case "shutdown": return onShutdown
    }
    throw UnsupportedErr("$msg")
  }

//////////////////////////////////////////////////////////////////////////
// Open
//////////////////////////////////////////////////////////////////////////

  private PyMgrSession onOpen(PyMgrSession session)
  {
    if (!running.val) throw Err("Not running")

    sessions.add(session.id, session)
    return session
  }

//////////////////////////////////////////////////////////////////////////
// Close
//////////////////////////////////////////////////////////////////////////

  // deallocates (does not close) the session
  internal Void removeSession(PyMgrSession session)
  {
    sessions.remove(session.id)
  }

//////////////////////////////////////////////////////////////////////////
// Shutdown
//////////////////////////////////////////////////////////////////////////

  private Obj? onShutdown()
  {
    running.val = false
    sessions.each |PyMgrSession session, Uuid id|
    {
      log.info("Killing python session: $id")
      session.onKill
    }
    return null
  }
}

**************************************************************************
** PyMgrSession
**************************************************************************

internal const class PyMgrSession : PySession, HxTaskAdjunct
{
  new make(PyMgr mgr, Dict opts)
  {
    this.id   = Uuid()
    this.mgr  = mgr
    this.opts = opts
  }

  const Uuid id
  const PyMgr mgr
  const Dict opts
  PySession session() { ((Unsafe)sessionRef.val).val }
  private const AtomicRef sessionRef := AtomicRef()

  private Log log() { mgr.lib.log }

  private Bool isClosed() { sessionRef.val == null }

//////////////////////////////////////////////////////////////////////////
// Open
//////////////////////////////////////////////////////////////////////////

  This open()
  {
    if (!isClosed) throw Err("Already open")

    docker := mgr.lib.rt.services.get(HxDockerService#)
    s := PyDockerSession(docker, opts)
    sessionRef.val = Unsafe(s)
    return this
  }

//////////////////////////////////////////////////////////////////////////
// PySession
//////////////////////////////////////////////////////////////////////////

  override This define(Str name, Obj? val)
  {
    session.define(name, val)
    return this
  }

  override This exec(Str code)
  {
    session.exec(code)
    return this
  }

  override This timeout(Duration? dur)
  {
    session.timeout(dur)
    return this
  }

  override Obj? eval(Str code)
  {
    try
    {
      return session.eval(code)
    }
    catch (TimeoutErr err)
    {
      this.close
      if (inTask) this.restart
      throw err
    }
    catch (Err err)
    {
      if (inTask) this.restart
      throw err
    }
  }

  override This close()
  {
    // kill the session if not running in a task
    if (!inTask) onKill
    return this
  }

  ** Restart the session, but only if running in a task
  private Void restart()
  {
    if (!inTask) return
    try
    {
      onClose
      this.open
    }
    catch (Err err)
    {
      onRemoveSession
      log.err("Could not restart persistent session. Killing it.", err)
      throw err
    }
  }

  private Void onClose()
  {
    if (isClosed) return
    try { session.close } catch (Err err) { log.err("Failed to close session", err) }
    sessionRef.val = null
  }

  private Void onRemoveSession()
  {
    mgr.removeSession(this)
  }

//////////////////////////////////////////////////////////////////////////
// HxTaskAdjunct
//////////////////////////////////////////////////////////////////////////

  override Void onKill()
  {
    // close the session
    onClose

    // deallocate python mgr session
    onRemoveSession
  }

//////////////////////////////////////////////////////////////////////////
// Util
//////////////////////////////////////////////////////////////////////////

  private Bool inTask() { mgr.taskSession != null }
}

**************************************************************************
** PyDockerSession
**************************************************************************

internal class PyDockerSession : PySession
{

//////////////////////////////////////////////////////////////////////////
// Constructor
//////////////////////////////////////////////////////////////////////////

  new open(HxDockerService dockerService, Dict opts)
  {
    this.dockerService = dockerService
    this.opts = opts

    // run docker container
    key    := Uuid()
    level  := ((Str)opts.get("logLevel", "WARN" )).upper
    port   := (opts.get("port") as Number)?.toInt ?: findOpenPort
    config := Str:Obj?[
      "cmd": ["-m", "hxpy", "--key", "$key", "--level", level],
      "exposedPorts": ["8888/tcp": [:]],
      "hostConfig": Str:Obj?[
        "portBindings": [
          "8888/tcp": [ ["hostPort": "$port"] ],
        ],
      ],
    ]

    this.cid = priorityImageNames(opts).eachWhile |image->Str?|
    {
      try
      {
        return dockerService.run(image, config)
      }
      catch (Err ignore) { return null }
    } ?: throw Err("Could not find any matching docker image: ${priorityImageNames(opts)}")

    // now connect the HxpySession with retries. retry is necessary because the
    // container might have started, but the python hxpy server might not yet
    // have opened the port for accepting connections
    retry := (opts.get("maxRetry") as Number)?.toInt ?: 5
    uri   := `tcp://localhost:${port}?key=${key}`
    while (true)
    {
      try
      {
        this.session = HxpySession.open(uri)
        break
      }
      catch (Err err)
      {
        if (--retry < 0)
        {
          this.close
          throw IOErr("Failed to connect to $uri", err)
        }
      }
      // sleep 1sec before retry
      Actor.sleep(1sec)
    }

    // configure timeout
    t := opts.get("timeout") as Number
    if (t != null) session.timeout(t.toDuration)
  }

  private static Str[] priorityImageNames(Dict opts)
  {
    // check if image name is explicitly specified
    x := opts.get("image") as Str
    if (x != null) return [x]

    // otherwise, try in this order
    ver := PyMgr#.pod.version
    return [
      "ghcr.io/haxall/hxpy:${ver}",
      "ghcr.io/haxall/hxpy:latest",
      "ghcr.io/haxall/hxpy:main",
    ]
  }

  ** This assume the docker daemon is running on the localhost. If we remove
  ** that assumption then we need to configure a port range for hxPy and
  ** explicitly cycle through that port range instead of finding random port.
  private static Int findOpenPort(Range range := Range.makeInclusive(10000, 30000))
  {
    attempts := 100
    i := 1
    r := Random.makeSecure
    port := r.next(range)
    while (i <= attempts)
    {
      s := TcpSocket()
      try
      {
        s.bind(IpAddr("localhost"), port)
        return port
      }
      catch (Err ignore) { }
      finally { s.close }
      ++i
    }
    throw IOErr("Cannot find free port in $range after $attempts attempts")
  }

  private HxDockerService dockerService

  ** Session options
  private const Dict opts

  ** Docker container id spawned by this session
  internal const Str cid

  ** HxpySession
  private HxpySession? session

//////////////////////////////////////////////////////////////////////////
// PySession
//////////////////////////////////////////////////////////////////////////

  override This define(Str name, Obj? val)
  {
    session.define(name, val)
    return this
  }

  override This exec(Str code)
  {
    session.exec(code)
    return this
  }

  override This timeout(Duration? dur)
  {
    session.timeout(dur)
    return this
  }

  override Obj? eval(Str code)
  {
    try
    {
      return session.eval(code)
    }
    // only catch timeout errors so we can keep around exited containers for inspection
    catch (TimeoutErr err)
    {
      this.close
      throw err
    }
  }

  override This close()
  {
    // delete the container
    try
    {
      dockerService.deleteContainer(this.cid)
    }
    catch (Err ignore)
    {
      // log.err("Failed to delete container $cid", err)
    }

    // close the session
    session?.close
    session = null

    return this
  }

}
