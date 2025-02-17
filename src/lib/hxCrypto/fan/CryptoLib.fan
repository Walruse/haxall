//
// Copyright (c) 2016, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//    3 Jan 2016  Brian Frank       Creation
//   31 Aug 2021  Matthew Giannini  Refactor for new Fantom crypto APIs
//    9 Sep 2021  Brian Frank       Refactor for Haxall
//

using crypto
using inet
using hx

using [java] java.lang::System

**
** Cryptographic certificate and key pair management
**
const class CryptoLib : HxLib, HxCryptoService
{
//////////////////////////////////////////////////////////////////////////
// Construction
//////////////////////////////////////////////////////////////////////////

  new make()
  {
    this.dir      = rt.dir.plus(`crypto/`).create
    this.keystore = CryptoKeyStore(rt.libs.actorPool, keystoreFile, log)
  }

//////////////////////////////////////////////////////////////////////////
// Identity
//////////////////////////////////////////////////////////////////////////

  ** Publish the HxCryptoService
  override HxService[] services() { [this] }

  ** Directory for crypto keystore file
  const File dir

  ** The keystore file to load
  private File keystoreFile() { dir.plus(`keystore.p12`) }

//////////////////////////////////////////////////////////////////////////
// HxCryptoService
//////////////////////////////////////////////////////////////////////////

  ** The keystore to store all trusted keys and certificates
  override const KeyStore keystore

  ** Get a keystore containing only the key aliased as "https".
  override KeyStore? httpsKey(Bool checked := true)
  {
    entry  := keystore.get("https", false) as PrivKeyEntry
    if (entry != null)
    {
      // create a single-entry keystore
      return Crypto.cur.loadKeyStore.set("https", entry)
    }
    if (checked) throw ArgErr("https key not found")
    return null
  }

  ** The host specific public/private key pair.
  override KeyPair hostKeyPair() { hostKey.keyPair }

  ** The host specific private key and certificate
  override PrivKeyEntry hostKey()
  {
    entry := keystore.get("host", false) as PrivKeyEntry
    if (entry == null)
    {
      // generate host key self-signed certificate
      pair := Crypto.cur.genKeyPair("RSA", 2048)
      csr  := Crypto.cur.genCsr(pair, "cn=skyarc.host")
      cert := Crypto.cur.certSigner(csr).sign
      entry = keystore.setPrivKey("host", pair.priv, [cert]).getPrivKey("host")
    }
    return entry
  }

//////////////////////////////////////////////////////////////////////////
// Lifecycle
//////////////////////////////////////////////////////////////////////////

  override Void onStart()
  {
    // crypto dir gets deleted in test mode, so use jvm truststore for tests
    if (rt.config.isTest) return

    // set the default truststore to use for all sockets
    SocketConfig.setCur(SocketConfig {
      it.truststore = this.keystore
    })

    // Set default trust store for native java apis (e.g. ldap)
    System.setProperty("javax.net.ssl.trustStoreType", "pkcs12")
    System.setProperty("javax.net.ssl.trustStore", keystoreFile.osPath)
    System.setProperty("javax.net.ssl.trustStorePassword", "changeit")
  }
}


