package com.argus.client

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

class DiscoveryManager(context: Context) {
    companion object {
        private const val TAG = "DiscoveryManager"
        private const val SERVICE_TYPE = "_argus._tcp."
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var resolveListener: NsdManager.ResolveListener? = null

    var onHostDiscovered: ((String) -> Unit)? = null

    fun startDiscovery() {
        if (discoveryListener != null) return

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.d(TAG, "Service discovery started")
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                Log.d(TAG, "Service found: ${service.serviceName}")
                if (service.serviceType.contains("_argus._tcp")) {
                    resolveService(service)
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                Log.e(TAG, "Service lost: ${service.serviceName}")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "Discovery stopped: $serviceType")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery failed: Error code:$errorCode")
                stopDiscovery()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery failed: Error code:$errorCode")
            }
        }

        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start discovery: ${e.message}")
        }
    }

    private fun resolveService(service: NsdServiceInfo) {
        resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "Resolve failed: $errorCode")
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Resolve Succeeded. ${serviceInfo.serviceName}")
                val host = serviceInfo.host.hostAddress
                if (host != null) {
                    Log.i(TAG, "Resolved IP: $host")
                    onHostDiscovered?.invoke(host)
                }
            }
        }
        try {
            nsdManager.resolveService(service, resolveListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resolve service: ${e.message}")
        }
    }

    fun stopDiscovery() {
        try {
            discoveryListener?.let {
                nsdManager.stopServiceDiscovery(it)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping discovery: ${e.message}")
        } finally {
            discoveryListener = null
        }
    }
}
