include $(TOPDIR)/rules.mk

PKG_NAME:=sqm-autorate-nss
PKG_VERSION:=20261127
PKG_RELEASE:=1

PKG_MAINTAINER:=nihilt <56614537+nihilt@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/sqm-autorate-nss
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Quality of Service
  TITLE:=Latency-aware rate control for the NSS SQM shaper
  URL:=https://github.com/nihilt/sqm-autorate-nss
  PKGARCH:=all
  DEPENDS:=+sqm-scripts +fping +perl +perlbase-fcntl +perlbase-io +perlbase-ipc +perlbase-posix +perlbase-symbol +perlbase-time
endef

define Package/sqm-autorate-nss/description
  A daemon that measures latency with fping and moves the rate of the NSS shaper (nsstbl)
  that nss-rk.qos builds, up when the line is quiet and down when queues build.
  Ships profiles, the helpers sqm-status and switch-profile, and a procd init script.
  Settings live in memory unless you ask for them to be kept across a reboot.
endef

define Package/sqm-autorate-nss/conffiles
/etc/sqm-default
/etc/sqm-profiles/sqm-autorate-custom.conf
/etc/sqm-profiles/sqm-autorate-debug.conf
/etc/sqm-profiles/sqm-autorate-gaming.conf
/etc/sqm-profiles/sqm-autorate-performance.conf
/etc/sqm-profiles/sqm-autorate-streaming.conf
/etc/logrotate.d/sqm-autorate
endef

define Build/Configure
endef

define Build/Compile
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/../../files $(PKG_BUILD_DIR)/
	$(CP) $(CURDIR)/../../LICENSE $(PKG_BUILD_DIR)/
endef

define Package/sqm-autorate-nss/install
	$(INSTALL_DIR) $(1)
	$(CP) $(PKG_BUILD_DIR)/files/* $(1)/
	chmod 755 $(1)/etc/init.d/sqm-autorate \
		$(1)/usr/bin/sqm-autorate.pl \
		$(1)/usr/bin/sqm-status \
		$(1)/usr/bin/switch-profile
	chmod 644 $(1)/usr/lib/sqm-autorate/common.sh
endef

$(eval $(call BuildPackage,sqm-autorate-nss))
