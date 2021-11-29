//
// Copyright (c) 2015, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   28 Oct 2015  Brian Frank  Creation
//   11 Aug 2020  Brian Frank  Rename FolioTracker to FolioHooks, add ns
//

using haystack

**
** Callback hooks including Namespace support and monitoring all committed diffs.
** All callbacks are on folio actor, so processing must be fast and anything
** expensive should be dispatched to other actors
**
@NoDoc
const mixin FolioHooks
{
  ** Def namespace is available
  abstract Namespace? ns(Bool checked := true)

  ** Callback before diff is committed during verify
  ** phase. An exception will cancel entire commit.
  ** Pass through FolioContext.commitInfo if available.
  abstract Void preCommit(FolioCommitEvent event)

  ** Callback after diff has been committed.
  ** Pass through FolioContext.commitInfo if available.
  abstract Void postCommit(FolioCommitEvent event)

  ** Callback after his write.  Result is same dict returned from future.
  ** There is no cxInfo since his writes may be coalesced.
  abstract Void postHisWrite(Dict rec, Dict result)
}

**************************************************************************
** FolioCommitEvent
**************************************************************************

**
** FolioCommitEvent is used for the pre/post commit hooks.
**
@NoDoc
abstract class FolioCommitEvent
{
  ** Diff changeset being committed.  During preCommit this the
  ** actual instance used by the client (where oldRec might just be
  ** an id and mod tag).  During postCommit this is the instance to
  ** return from commit fully flushed out with oldRec and newRec.
  abstract Diff diff()

  ** Actual current record looked up during preCommit
  abstract Dict? oldRec()

  ** FolioContext.commitInfo if available
  abstract Obj? cxInfo()
}

**************************************************************************
** NilTracker
**************************************************************************

**
** NilHooks is the default no-op for all callbacks
**
internal const class NilHooks : FolioHooks
{
  override Namespace? ns(Bool checked := true) { if (checked) throw UnsupportedErr("Namespace not availble"); return null }
  override Void preCommit(FolioCommitEvent event) {}
  override Void postCommit(FolioCommitEvent event) {}
  override Void postHisWrite(Dict rec, Dict result) {}
}



