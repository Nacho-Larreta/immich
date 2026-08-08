package app.alextran.immich.connectivity

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager

class ConnectivityApiImpl(
  context: Context,
  private val flutterApi: ConnectivityFlutterApi,
) : ConnectivityApi {
  private val connectivityManager =
    context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
  private val wifiManager =
    context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
  private val lifecycleLock = Any()
  private var started = false
  private val callback = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) = emitSnapshot()

    override fun onLost(network: Network) = emitSnapshot()

    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
      emitSnapshot()
  }

  override fun getSnapshot(): ConnectivityTransportSnapshot {
    val capabilities = connectivityManager.getNetworkCapabilities(connectivityManager.activeNetwork)
      ?: return ConnectivityTransportSnapshot(
        ConnectivityTransportAvailability.UNAVAILABLE,
        emptyList(),
      )

    return ConnectivityTransportSnapshot(
      ConnectivityTransportAvailability.AVAILABLE,
      networkCapabilities(capabilities),
    )
  }

  override fun start() {
    synchronized(lifecycleLock) {
      if (started) return
      connectivityManager.registerDefaultNetworkCallback(callback)
      started = true
    }
    emitSnapshot()
  }

  override fun stop() {
    synchronized(lifecycleLock) {
      if (!started) return
      connectivityManager.unregisterNetworkCallback(callback)
      started = false
    }
  }

  override fun dispose() = stop()

  private fun emitSnapshot() {
    flutterApi.onTransportChanged(getSnapshot()) { }
  }

  private fun networkCapabilities(
    capabilities: NetworkCapabilities,
  ): List<ConnectivityNetworkCapability> {
    val hasWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
      capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
    val hasCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
    val hasVpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    val isUnmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)

    return buildList {
      if (hasWifi) add(ConnectivityNetworkCapability.WIFI)
      if (hasCellular) add(ConnectivityNetworkCapability.CELLULAR)
      if (hasVpn) {
        add(ConnectivityNetworkCapability.VPN)
        if (!hasWifi && !hasCellular) {
          if (wifiManager.isWifiEnabled) add(ConnectivityNetworkCapability.WIFI)
          else add(ConnectivityNetworkCapability.CELLULAR)
        }
      }
      if (isUnmetered) add(ConnectivityNetworkCapability.UNMETERED)
    }
  }
}
