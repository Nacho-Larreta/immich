package app.alextran.immich.connectivity

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.util.concurrent.atomic.AtomicLong

internal data class ConnectivityNetworkValue(
  val available: Boolean,
  val usesWifi: Boolean = false,
  val usesCellular: Boolean = false,
  val usesVpn: Boolean = false,
  val isUnmetered: Boolean = false,
)

internal interface ConnectivityNetworkMonitoring {
  fun readCurrent(): ConnectivityNetworkValue
  fun start(onChanged: () -> Unit)
  fun stop()
}

private class AndroidConnectivityNetworkMonitor(context: Context) : ConnectivityNetworkMonitoring {
  private val manager =
    context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
  private var onChanged: (() -> Unit)? = null
  private val callback = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) = publishChange()

    override fun onLost(network: Network) = publishChange()

    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = publishChange()
  }

  override fun readCurrent(): ConnectivityNetworkValue {
    val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
      ?: return ConnectivityNetworkValue(available = false)
    return ConnectivityNetworkValue(
      available = true,
      usesWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE),
      usesCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
      usesVpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
      isUnmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
    )
  }

  override fun start(onChanged: () -> Unit) {
    this.onChanged = onChanged
    manager.registerDefaultNetworkCallback(callback)
  }

  override fun stop() {
    onChanged = null
    manager.unregisterNetworkCallback(callback)
  }

  private fun publishChange() {
    onChanged?.invoke()
  }
}

private object ConnectivityMonitorEpochAuthority {
  private val epoch = AtomicLong()

  fun next(): Long {
    while (true) {
      val current = epoch.get()
      check(current < Long.MAX_VALUE) { "Connectivity monitor epoch exhausted" }
      if (epoch.compareAndSet(current, current + 1)) return current + 1
    }
  }
}

class ConnectivityApiImpl internal constructor(
  private val networkMonitor: ConnectivityNetworkMonitoring,
  private val publish: (ConnectivityTransportSnapshot) -> Unit,
) : ConnectivityApi {
  constructor(context: Context, flutterApi: ConnectivityFlutterApi) : this(
    AndroidConnectivityNetworkMonitor(context),
    { snapshot -> flutterApi.onTransportChanged(snapshot) { } },
  )

  private val lifecycleLock = Any()
  private var started = false
  private var monitorEpoch = 0L
  private var revision = 0L

  override fun readCurrentSnapshot(): ConnectivityTransportSnapshot = synchronized(lifecycleLock) {
    currentSnapshot()
  }

  override fun start() {
    synchronized(lifecycleLock) {
      if (started) return
      monitorEpoch = ConnectivityMonitorEpochAuthority.next()
      revision = 0
      networkMonitor.start(::emitSnapshot)
      started = true
    }
    emitSnapshot()
  }

  override fun stop() {
    synchronized(lifecycleLock) {
      if (!started) return
      networkMonitor.stop()
      started = false
      monitorEpoch = ConnectivityMonitorEpochAuthority.next()
      revision = 0
    }
  }

  override fun dispose() = stop()

  private fun emitSnapshot() {
    val snapshot = synchronized(lifecycleLock) {
      if (!started) return
      revision++
      currentSnapshot()
    }
    publish(snapshot)
  }

  private fun currentSnapshot(): ConnectivityTransportSnapshot {
    val network = networkMonitor.readCurrent()
    if (!network.available) {
      return ConnectivityTransportSnapshot(
        ConnectivityTransportAvailability.UNAVAILABLE,
        emptyList(),
        monitorEpoch,
        revision,
      )
    }
    return ConnectivityTransportSnapshot(
      ConnectivityTransportAvailability.AVAILABLE,
      buildList {
        if (network.usesWifi) add(ConnectivityNetworkCapability.WIFI)
        if (network.usesCellular) add(ConnectivityNetworkCapability.CELLULAR)
        if (network.usesVpn) add(ConnectivityNetworkCapability.VPN)
        if (network.isUnmetered) add(ConnectivityNetworkCapability.UNMETERED)
      },
      monitorEpoch,
      revision,
    )
  }
}
