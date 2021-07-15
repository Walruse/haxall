//
// Copyright (c) 2012, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   18 Jul 2012  Brian Frank  Creation
//   14 Jul 2021  Brian Frank  Refactor for Haxall
//

using concurrent
using haystack
using obs
using folio
using hx

**
** Point historization and writable support
**
const class PointLib : HxLib
{
  new make()
  {
    enums = EnumDefs()
    writeMgr = WriteMgrActor(this)
    observables = [writeMgr.observable]
  }

  ** Return list of observables this library publishes
  override const Observable[] observables

  ** Start callback
  override Void onStart()
  {
    if (rec.missing("disableWritables"))  writeMgr.onStart
    //if (rec.missing("disableHisCollect")) hisCollects.onStart
    //if (rec.has("demoMode")) demo.onStart

    // subscribe to point commits
    observe("obsCommits",
      Etc.makeDict([
        "obsAdds":      Marker.val,
        "obsUpdates":   Marker.val,
        "obsRemoves":   Marker.val,
        "obsAddOnInit": Marker.val,
        "syncable":     Marker.val,
        "obsFilter":   "point"
      ]), #onPointEvent)

    // subscribe to enumMeta commits
    observe("obsCommits",
      Etc.makeDict([
        "obsAdds":      Marker.val,
        "obsUpdates":   Marker.val,
        "obsRemoves":   Marker.val,
        "obsAddOnInit": Marker.val,
        "syncable":     Marker.val,
        "obsFilter":   "enumMeta"
      ]), #onEnumMetaEvent)

  }

  ** Event when 'enumMeta' record is modified
  internal Void onEnumMetaEvent(CommitObservation? e)
  {
    // null is sync message
    if (e == null) return

    newRec := e.newRec
    if (newRec.has("trash")) newRec = Etc.emptyDict
    enums.updateMeta(newRec, log)
  }

  ** Event when 'point' record is modified
  internal Void onPointEvent(CommitObservation? e)
  {
    // null is sync message
    if (e == null)
    {
      writeMgr.sync
      return
    }

    // check for writable changes
    if (e.recHas("writable")) writeMgr.send(HxMsg("obs", e))
  }

  internal const EnumDefs enums
  internal const WriteMgrActor writeMgr
}


