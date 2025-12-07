include $(TOPDIR)/rules.mk

PKG_NAME:=sqm-autorate-nss
PKG_VERSION:=20251207
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/sqm-autorate-nss
  TITLE:=SQM scripts for NSS enabled builds
  DEPENDS:=+sqm-scripts +jsonfilter +perl +perlbase-file +perlbase-getopt +perlbase-time +perlbase-threads +ip-full +tc-full +iputils-ping +logrotate +procps-ng +coreutils +procd
  PKGARCH:=all
  SECTION:=base
endef

define Package/sqm-autorate-nss/description
 SQM-Autorate-NSS: latency-aware SQM daemon for OpenWrt NSS builds, adjusting nsstbl rates via nss-rk.qos.
endef

define Build/Configure
endef

define Build/Compile
endef

define Build/Prepare
    mkdir -p $(PKG_BUILD_DIR)
    $(CP) $(CURDIR)/../../files/ $(PKG_BUILD_DIR)
endef

define Package/sqm-autorate-nss/install
    $(INSTALL_DIR) $(1)
    $(CP) $(PKG_BUILD_DIR)/files/* $(1)/
endef

$(eval $(call BuildPackage,sqm-autorate-nss))

