import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:event_taxi/event_taxi.dart';
import 'package:natrium_wallet_flutter/ui/widgets/auto_resize_text.dart';
import 'package:natrium_wallet_flutter/appstate_container.dart';
import 'package:natrium_wallet_flutter/colors.dart';
import 'package:natrium_wallet_flutter/dimens.dart';
import 'package:natrium_wallet_flutter/localization.dart';
import 'package:natrium_wallet_flutter/model/list_model.dart';
import 'package:natrium_wallet_flutter/model/db/contact.dart';
import 'package:natrium_wallet_flutter/model/db/appdb.dart';
import 'package:natrium_wallet_flutter/network/model/block_types.dart';
import 'package:natrium_wallet_flutter/network/model/response/account_history_response_item.dart';
import 'package:natrium_wallet_flutter/styles.dart';
import 'package:natrium_wallet_flutter/app_icons.dart';
import 'package:natrium_wallet_flutter/ui/contacts/add_contact.dart';
import 'package:natrium_wallet_flutter/ui/send/send_sheet.dart';
import 'package:natrium_wallet_flutter/ui/send/send_confirm_sheet.dart';
import 'package:natrium_wallet_flutter/ui/send/send_complete_sheet.dart';
import 'package:natrium_wallet_flutter/ui/receive/receive_sheet.dart';
import 'package:natrium_wallet_flutter/ui/settings/settings_drawer.dart';
import 'package:natrium_wallet_flutter/ui/widgets/buttons.dart';
import 'package:natrium_wallet_flutter/ui/widgets/app_drawer.dart';
import 'package:natrium_wallet_flutter/ui/widgets/app_scaffold.dart';
import 'package:natrium_wallet_flutter/ui/widgets/sheets.dart';
import 'package:natrium_wallet_flutter/ui/util/routes.dart';
import 'package:natrium_wallet_flutter/ui/widgets/reactive_refresh.dart';
import 'package:natrium_wallet_flutter/ui/util/ui_util.dart';
import 'package:natrium_wallet_flutter/util/sharedprefsutil.dart';
import 'package:natrium_wallet_flutter/util/numberutil.dart';
import 'package:natrium_wallet_flutter/util/fileutil.dart';
import 'package:natrium_wallet_flutter/util/hapticutil.dart';
import 'package:qr/qr.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:natrium_wallet_flutter/bus/events.dart';

class AppHomePage extends StatefulWidget {
  @override
  _AppHomePageState createState() => _AppHomePageState();
}

class _AppHomePageState extends State<AppHomePage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final GlobalKey<AppScaffoldState> _scaffoldKey = new GlobalKey<AppScaffoldState>();

  // Controller for placeholder card animations
  AnimationController _placeholderCardAnimationController;
  Animation<double> _opacityAnimation;
  bool _animationDisposed;

  // Receive card instance
  AppReceiveSheet receive;

  // A separate unfortunate instance of this list, is a little unfortunate
  // but seems the only way to handle the animations
  ListModel<AccountHistoryResponseItem> _historyList;

  // List of contacts (Store it so we only have to query the DB once for transaction cards)
  List<Contact> _contacts = List();

  // Price conversion state (BTC, NANO, NONE)
  PriceConversion _priceConversion;
  TextStyle _convertedPriceStyle = AppStyles.TextStyleCurrencyAlt;

  bool _isRefreshing = false;

  bool _lockDisabled = false; // whether we should avoid locking the app

  // FCM instance
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging();

  @override
  void initState() {
    super.initState();
    _registerBus();
    WidgetsBinding.instance.addObserver(this);
    SharedPrefsUtil.inst.getPriceConversion().then((result) {
      _priceConversion = result;
    });
    _addSampleContact();
    _updateContacts();
    // Setup placeholder animation and start
    _animationDisposed = false;
    _placeholderCardAnimationController = new AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _placeholderCardAnimationController.addListener(_animationControllerListener);
    _opacityAnimation =
        new Tween(begin: 1.0, end: 0.4).animate(
      CurvedAnimation(
        parent: _placeholderCardAnimationController,
        curve: Curves.easeIn,
        reverseCurve: Curves.easeOut,
      ),
    );
    _opacityAnimation.addStatusListener(_animationStatusListener);
    _placeholderCardAnimationController.forward();
    // Register push notifications
    _firebaseMessaging.configure(
      onMessage: (Map<String, dynamic> message) async {
        print("onMessage: $message");
      },
      onLaunch: (Map<String, dynamic> message) async {
        print("onLaunch: $message");
      },
      onResume: (Map<String, dynamic> message) async {
        print("onResume: $message");
      },
    );
    _firebaseMessaging.requestNotificationPermissions(
        const IosNotificationSettings(sound: true, badge: true, alert: true));
    _firebaseMessaging.onIosSettingsRegistered
        .listen((IosNotificationSettings settings) {
      if (settings.alert || settings.badge || settings.sound) {
        SharedPrefsUtil.inst.setDisabledNotificationsIos(false);
        SharedPrefsUtil.inst.getNotificationsSet().then((beenSet) {
          if (!beenSet) {
            SharedPrefsUtil.inst.setNotificationsOn(true);
          }
        });
        _firebaseMessaging.getToken().then((String token) {
          if (token != null) {
            EventTaxiImpl.singleton().fire(FcmUpdateEvent(token: token));
          }
        });
      } else {
        SharedPrefsUtil.inst.setDisabledNotificationsIos(true);
        SharedPrefsUtil.inst.setNotificationsOn(false).then((_) {
          _firebaseMessaging.getToken().then((String token) {
            EventTaxiImpl.singleton().fire(FcmUpdateEvent(token: token));
          });
        });
      }
    });
    _firebaseMessaging.getToken().then((String token) {
      if (token != null) {
        EventTaxiImpl.singleton().fire(FcmUpdateEvent(token: token));
      }
    });
  }

  void _animationStatusListener(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.dismissed:
        _placeholderCardAnimationController.forward();
        break;
      case AnimationStatus.completed:
        _placeholderCardAnimationController.reverse();
        break;
      default:
        return null;
    }    
  }

  void _animationControllerListener() {
    setState(() {});
  }

  void _disposeAnimation() {
    if (!_animationDisposed) {
      _animationDisposed = true;
      _opacityAnimation.removeStatusListener(_animationStatusListener);
      _placeholderCardAnimationController.removeListener(_animationControllerListener);
      _placeholderCardAnimationController.stop();
    }
  }

  /// Add donations contact if it hasnt already been added
  Future<void> _addSampleContact() async {
    bool contactAdded = await SharedPrefsUtil.inst.getFirstContactAdded();
    if (!contactAdded) {
      DBHelper db = DBHelper();
      bool addressExists = await db.contactExistsWithAddress(
          "xrb_1natrium1o3z5519ifou7xii8crpxpk8y65qmkih8e8bpsjri651oza8imdd");
      if (addressExists) {
        return;
      }
      bool nameExists = await db.contactExistsWithName("@NatriumDonations");
      if (nameExists) {
        return;
      }
      await SharedPrefsUtil.inst.setFirstContactAdded(true);
      Contact c = Contact(
          name: "@NatriumDonations",
          address:
              "xrb_1natrium1o3z5519ifou7xii8crpxpk8y65qmkih8e8bpsjri651oza8imdd");
      await db.saveContact(c);
    }
  }

  void _updateContacts() {
    DBHelper().getContacts().then((contacts) {
      setState(() {
        _contacts = contacts;
      });
    });
  }

  StreamSubscription<HistoryHomeEvent> _historySub;
  StreamSubscription<ContactModifiedEvent> _contactModifiedSub;
  StreamSubscription<SendCompleteEvent> _sendCompleteSub;
  StreamSubscription<DisableLockTimeoutEvent> _disableLockSub;
  StreamSubscription<DeepLinkEvent> _deepLinkEventSub;

  void _registerBus() {
    _historySub = EventTaxiImpl.singleton().registerTo<HistoryHomeEvent>().listen((event) {
      diffAndUpdateHistoryList(event.items);
      setState(() {
        _isRefreshing = false;
      });
    });
    _sendCompleteSub = EventTaxiImpl.singleton().registerTo<SendCompleteEvent>().listen((event) {
      // Route to send complete if received process response for send block
      if (event.previous != null) {
        // Route to send complete
        String displayAmount =
            NumberUtil.getRawAsUsableString(event.previous.sendAmount);
        DBHelper().getContactWithAddress(event.previous.link).then((contact) {
          String contactName = contact == null ? null : contact.name;
          Navigator.of(context).popUntil(RouteUtils.withNameLike('/home'));
          AppSendCompleteSheet(displayAmount, event.previous.link, contactName, localAmount: event.previous.localCurrencyValue)
              .mainBottomSheet(context);
        });
      }
    });
    _contactModifiedSub = EventTaxiImpl.singleton().registerTo<ContactModifiedEvent>().listen((event) {
      _updateContacts();
    });
    _deepLinkEventSub = EventTaxiImpl.singleton().registerTo<DeepLinkEvent>().listen((event) {
      String amount;
      String contactName;
      if (event.sendAmount != null) {
        // Require minimum 1 BANOSHI to send
        if (BigInt.parse(event.sendAmount) >= BigInt.from(10).pow(27)) {
          amount = event.sendAmount;
        }
      }
      // See if a contact
      DBHelper().getContactWithAddress(event.sendDestination).then((contact) {
        if (contact != null) {
          contactName = contact.name;
        }
        // Remove any other screens from stack
        Navigator.of(context).popUntil(RouteUtils.withNameLike('/home'));
        if (amount != null) {
          // Go to send confirm with amount
          AppSendConfirmSheet(
                  NumberUtil.getRawAsUsableString(amount).replaceAll(",", ""),
                  event.sendDestination,
                  contactName: contactName)
              .mainBottomSheet(context);
        } else {
          // Go to send with address
          AppSendSheet(contact: contact, address: event.sendDestination)
              .mainBottomSheet(context);
        }
      });      
    });
    // Hackish event to block auto-lock functionality
    _disableLockSub = EventTaxiImpl.singleton().registerTo<DisableLockTimeoutEvent>().listen((event) {
      if (event.disable) {
        cancelLockEvent();
      }
      _lockDisabled = event.disable;
    });
  }

  @override
  void dispose() {
    _destroyBus();
    WidgetsBinding.instance.removeObserver(this);
    _placeholderCardAnimationController.dispose();
    super.dispose();
  }

  void _destroyBus() {
    if (_historySub != null) {
      _historySub.cancel();
    }
    if (_contactModifiedSub != null) {
      _contactModifiedSub.cancel();
    }
    if (_sendCompleteSub != null) {
      _sendCompleteSub.cancel();
    }
    if (_disableLockSub != null) {
      _disableLockSub.cancel();
    }
    if (_deepLinkEventSub != null) {
      _deepLinkEventSub.cancel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle websocket connection when app is in background
    // terminate it to be eco-friendly
    switch (state) {
      case AppLifecycleState.paused:
        setAppLockEvent();
        StateContainer.of(context).disconnect();
        super.didChangeAppLifecycleState(state);
        break;
      case AppLifecycleState.resumed:
        cancelLockEvent();
        StateContainer.of(context).reconnect();
        super.didChangeAppLifecycleState(state);
        break;
      default:
        super.didChangeAppLifecycleState(state);
        break;
    }
  }

  // To lock and unlock the app
  StreamSubscription<dynamic> lockStreamListener;

  Future<void> setAppLockEvent() async {
    if (await SharedPrefsUtil.inst.getLock() && !_lockDisabled) {
      if (lockStreamListener != null) {
        lockStreamListener.cancel();
      }
      Future<dynamic> delayed = new Future.delayed((await SharedPrefsUtil.inst.getLockTimeout()).getDuration());
      delayed.then((_) {
        return true;
      });
      lockStreamListener = delayed.asStream().listen((_) {
        Navigator.of(context).pushReplacementNamed('/');
      });
    }
  }

  Future<void> cancelLockEvent() async {
    if (lockStreamListener != null) {
      lockStreamListener.cancel();
    }
  }

  // Used to build list items that haven't been removed.
  Widget _buildItem(
      BuildContext context, int index, Animation<double> animation) {
    String displayName = smallScreen(context)
        ? _historyList[index].getShorterString()
        : _historyList[index].getShortString();
    _contacts.forEach((contact) {
      if (contact.address == _historyList[index].account) {
        displayName = contact.name;
      }
    });
    return _buildTransactionCard(
        _historyList[index], animation, displayName, context);
  }

  // Return widget for list
  Widget _getListWidget(BuildContext context) {
    if (StateContainer.of(context).wallet.historyLoading) {
      // Loading Animation
      return ReactiveRefreshIndicator(
        backgroundColor: AppColors.backgroundDark,
        onRefresh: _refresh,
        isRefreshing: _isRefreshing,
        child: ListView(
        padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
        children: <Widget>[
          _buildLoadingTransactionCard(
              "Sent", "10244000", "123456789121234", context),
          _buildLoadingTransactionCard(
              "Received", "100,00000", "@bbedwards1234", context),
          _buildLoadingTransactionCard(
              "Sent", "14500000", "12345678912345671234", context),
          _buildLoadingTransactionCard(
              "Sent", "12,51200", "123456789121234", context),
          _buildLoadingTransactionCard(
              "Received", "1,45300", "123456789121234", context),
          _buildLoadingTransactionCard(
              "Sent", "100,00000", "12345678912345671234", context),
          _buildLoadingTransactionCard(
              "Received", "24,00000", "12345678912345671234", context),
          _buildLoadingTransactionCard(
              "Sent", "1,00000", "123456789121234", context),
        ],
      ));
    } else if (StateContainer.of(context).wallet.history.length == 0) {
      _disposeAnimation();
      return ReactiveRefreshIndicator(
        backgroundColor: AppColors.backgroundDark,
        child: ListView(
          padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
          children: <Widget>[
            _buildWelcomeTransactionCard(context),
            _buildDummyTransactionCard(
                AppLocalization.of(context).sent, AppLocalization.of(context).exampleCardLittle, AppLocalization.of(context).exampleCardTo, context),
            _buildDummyTransactionCard(
                AppLocalization.of(context).received, AppLocalization.of(context).exampleCardLot,AppLocalization.of(context).exampleCardFrom, context),
          ],
        ),
        onRefresh: _refresh,
        isRefreshing: _isRefreshing,
      );
    } else {
      _disposeAnimation();
    }
    // Setup history list
    if (_historyList == null) {
      setState(() {
        _historyList = ListModel<AccountHistoryResponseItem>(
          listKey: _listKey,
          initialItems: StateContainer.of(context).wallet.history,
        );
      });
    }
    return ReactiveRefreshIndicator(
      backgroundColor: AppColors.backgroundDark,
      child: AnimatedList(
        key: _listKey,
        padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
        initialItemCount: _historyList.length,
        itemBuilder: _buildItem,
      ),
      onRefresh: _refresh,
      isRefreshing: _isRefreshing,
    );
  }

  // Refresh list
  Future<void> _refresh() async {
    setState(() {
      _isRefreshing = true;
    });
    HapticUtil.success();
    StateContainer.of(context).requestUpdate();
    // Hide refresh indicator after 3 seconds if no server response
    Future.delayed(new Duration(seconds: 3), () {
      setState(() {
        _isRefreshing = false;
      });   
    });
  }

  ///
  /// Because there's nothing convenient like DiffUtil, some manual logic
  /// to determine the differences between two lists and to add new items.
  ///
  /// Depends on == being overriden in the AccountHistoryResponseItem class
  ///
  /// Required to do it this way for the animation
  ///
  void diffAndUpdateHistoryList(List<AccountHistoryResponseItem> newList) {
    if (newList == null || newList.length == 0 || _historyList == null) return;
    // Get items not in current list, and add them from top-down
    newList.reversed.where((item) => !_historyList.items.contains(item)).forEach((historyItem) {
      setState(() {
        _historyList.insertAtTop(historyItem);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (receive == null) {
      QrPainter painter = QrPainter(
        data: StateContainer.of(context).wallet.address,
        version: 6,
        errorCorrectionLevel: QrErrorCorrectLevel.Q,
      );
      painter.toImageData(MediaQuery.of(context).size.width).then((byteData) {
        setState(() {
          receive = AppReceiveSheet(Container(
              width: MediaQuery.of(context).size.width / 2.675,
              child: Image.memory(byteData.buffer.asUint8List())));
        });
      });
    }

    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light.copyWith(
        statusBarIconBrightness: Brightness.light,
        statusBarColor: Colors.transparent));
    return AppScaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      drawer: SizedBox(
        width: UIUtil.drawerWidth(context),
        child: AppDrawer(
          child: SettingsSheet(),
        ),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          //Main Card
          _buildMainCard(context, _scaffoldKey),
          //Main Card End

          //Transactions Text
          Container(
            margin: EdgeInsets.fromLTRB(30.0, 20.0, 26.0, 0.0),
            child: Row(
              children: <Widget>[
                Text(
                  AppLocalization.of(context).transactions.toUpperCase(),
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w100,
                    color: AppColors.text,
                  ),
                ),
              ],
            ),
          ), //Transactions Text End

          //Transactions List
          Expanded(
            child: Stack(
              children: <Widget>[
                _getListWidget(context),
                //List Top Gradient End
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 10.0,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.background00,
                          AppColors.background
                        ],
                        begin: Alignment(0.5, 1.0),
                        end: Alignment(0.5, -1.0),
                      ),
                    ),
                  ),
                ), // List Top Gradient End

                //List Bottom Gradient
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: 30.0,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.background00,
                          AppColors.background
                        ],
                        begin: Alignment(0.5, -1),
                        end: Alignment(0.5, 0.5),
                      ),
                    ),
                  ),
                ), //List Bottom Gradient End
              ],
            ),
          ), //Transactions List End

          //Buttons Area
          Container(
            color: AppColors.background,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    margin: EdgeInsets.fromLTRB(14.0, 0.0, 7.0,
                        MediaQuery.of(context).size.height * 0.035),
                    child: FlatButton(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100.0)),
                      color: receive != null
                          ? AppColors.primary
                          : AppColors.primary60,
                      child: Text(AppLocalization.of(context).receive,
                          textAlign: TextAlign.center,
                          style: AppStyles.TextStyleButtonPrimary),
                      padding:
                          EdgeInsets.symmetric(vertical: 14.0, horizontal: 20),
                      onPressed: () {
                        if (receive == null) {
                          return;
                        }
                        receive.mainBottomSheet(context);
                      },
                      highlightColor: receive != null
                          ? AppColors.background40
                          : Colors.transparent,
                      splashColor: receive != null
                          ? AppColors.background40
                          : Colors.transparent,
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: EdgeInsets.fromLTRB(7.0, 0.0, 14.0,
                        MediaQuery.of(context).size.height * 0.035),
                    child: FlatButton(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100.0)),
                      color: StateContainer.of(context).wallet.accountBalance >
                              BigInt.zero
                          ? AppColors.primary
                          : AppColors.primary60,
                      child: Text(AppLocalization.of(context).send,
                          textAlign: TextAlign.center,
                          style: AppStyles.TextStyleButtonPrimary),
                      padding:
                          EdgeInsets.symmetric(vertical: 14.0, horizontal: 20),
                      onPressed: () {
                        if (StateContainer.of(context).wallet.accountBalance >
                            BigInt.zero) {
                          AppSendSheet().mainBottomSheet(context);
                        }
                      },
                      highlightColor:
                          StateContainer.of(context).wallet.accountBalance >
                                  BigInt.zero
                              ? AppColors.background40
                              : Colors.transparent,
                      splashColor:
                          StateContainer.of(context).wallet.accountBalance >
                                  BigInt.zero
                              ? AppColors.background40
                              : Colors.transparent,
                    ),
                  ),
                ),
              ],
            ),
          ), //Buttons Area End
        ],
      ),
    );
  }

// Transaction Card/List Item
  Widget _buildTransactionCard(AccountHistoryResponseItem item,
      Animation<double> animation, String displayName, BuildContext context) {
    TransactionDetailsSheet transactionDetails =
        TransactionDetailsSheet(item.hash, item.account, displayName);
    String text;
    IconData icon;
    Color iconColor;
    if (item.type == BlockTypes.SEND) {
      text = AppLocalization.of(context).sent;
      icon = AppIcons.sent;
      iconColor = AppColors.text60;
    } else {
      text = AppLocalization.of(context).received;
      icon = AppIcons.received;
      iconColor = AppColors.primary60;
    }
    return SizeTransition(
      axis: Axis.vertical,
      axisAlignment: -1.0,
      sizeFactor: animation,
      child: Container(
        margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
        decoration: BoxDecoration(
          color: AppColors.backgroundDark,
          borderRadius: BorderRadius.circular(10.0),
        ),
        child: FlatButton(
          highlightColor: AppColors.text15,
          splashColor: AppColors.text15,
          color: AppColors.backgroundDark,
          padding: EdgeInsets.all(0.0),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
          onPressed: () => transactionDetails.mainBottomSheet(context),
          child: Center(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                          margin: EdgeInsets.only(right: 16.0),
                          child: Icon(icon, color: iconColor, size: 20)),
                      Container(
                        width: MediaQuery.of(context).size.width / 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              text,
                              textAlign: TextAlign.left,
                              style: AppStyles.TextStyleTransactionType,
                            ),
                            RichText(
                              textAlign: TextAlign.left,
                              text: TextSpan(
                                text: '',
                                children: [
                                  TextSpan(
                                    text: item.getFormattedAmount(),
                                    style:
                                        AppStyles.TextStyleTransactionAmount,
                                  ),
                                  TextSpan(
                                    text: " NANO",
                                    style:
                                        AppStyles.TextStyleTransactionUnit,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Container(
                    width: MediaQuery.of(context).size.width / 2.4,
                    child: Text(
                      displayName,
                      textAlign: TextAlign.right,
                      style: AppStyles.TextStyleTransactionAddress,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  } //Transaction Card End

  // Dummy Transaction Card
  Widget _buildDummyTransactionCard(
      String type, String amount, String address, BuildContext context) {
    String text;
    IconData icon;
    Color iconColor;
    if (type == "Sent") {
      text = "Sent";
      icon = AppIcons.sent;
      iconColor = AppColors.text60;
    } else {
      text = "Received";
      icon = AppIcons.received;
      iconColor = AppColors.primary60;
    }
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: AppColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: FlatButton(
        onPressed: () {
          return null;
        },
        highlightColor: AppColors.text15,
        splashColor: AppColors.text15,
        color: AppColors.backgroundDark,
        padding: EdgeInsets.all(0.0),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                        margin: EdgeInsets.only(right: 16.0),
                        child: Icon(icon, color: iconColor, size: 20)),
                    Container(
                      width: MediaQuery.of(context).size.width / 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            text,
                            textAlign: TextAlign.left,
                            style: AppStyles.TextStyleTransactionType,
                          ),
                          RichText(
                            textAlign: TextAlign.left,
                            text: TextSpan(
                              text: '',
                              children: [
                                TextSpan(
                                  text: amount,
                                  style:
                                      AppStyles.TextStyleTransactionAmount,
                                ),
                                TextSpan(
                                  text: " NANO",
                                  style: AppStyles.TextStyleTransactionUnit,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Container(
                  width: MediaQuery.of(context).size.width / 2.4,
                  child: Text(
                    address,
                    textAlign: TextAlign.right,
                    style: AppStyles.TextStyleTransactionAddress,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } //Dummy Transaction Card End

  // Welcome Card
  TextSpan _getExampleHeaderSpan(BuildContext context) {
    String workingStr = AppLocalization.of(context).exampleCardIntro;
    if (!workingStr.contains("NANO")) {
      return TextSpan(
        text: workingStr,
        style: AppStyles.TextStyleTransactionWelcome,
      );   
    }
    // Colorize NANO
    List<String> splitStr = workingStr.split("NANO");
    if (splitStr.length != 2) {
      return TextSpan(
        text: workingStr,
        style: AppStyles.TextStyleTransactionWelcome,
      );   
    }
    return TextSpan(
      text: '',
      children: [
        TextSpan(
          text: splitStr[0],
          style: AppStyles.TextStyleTransactionWelcome,
        ),
        TextSpan(
          text: "NANO",
          style: AppStyles.TextStyleTransactionWelcomePrimary,
        ),
        TextSpan(
          text: splitStr[1],
          style: AppStyles.TextStyleTransactionWelcome,
        ),
      ],
    );
  }

  Widget _buildWelcomeTransactionCard(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: AppColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Container(
              width: 7.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(10.0),
                    bottomLeft: Radius.circular(10.0)),
                color: AppColors.primary,
              ),
            ),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    vertical: 14.0, horizontal: 15.0),
                child: RichText(
                  textAlign: TextAlign.center,
                  text: _getExampleHeaderSpan(context),
                ),
              ),
            ),
            Container(
              width: 7.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                    topRight: Radius.circular(10.0),
                    bottomRight: Radius.circular(10.0)),
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  } // Welcome Card End

  // Dummy Transaction Card
  Widget _buildLoadingTransactionCard(
      String type, String amount, String address, BuildContext context) {
    String text;
    IconData icon;
    Color iconColor;
    if (type == "Sent") {
      text = "Senttt";
      icon = AppIcons.dotfilled;
      iconColor = AppColors.text20;
    } else {
      text = "Receiveddd";
      icon = AppIcons.dotfilled;
      iconColor = AppColors.primary20;
    }
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: AppColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: FlatButton(
        onPressed: () {
          return null;
        },
        highlightColor: AppColors.text15,
        splashColor: AppColors.text15,
        color: AppColors.backgroundDark,
        padding: EdgeInsets.all(0.0),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    // Transaction Icon
                    Opacity(
                      opacity: _opacityAnimation.value,
                      child: Container(
                          margin: EdgeInsets.only(right: 16.0),
                          child: Icon(icon, color: iconColor, size: 20)),
                    ),
                    Container(
                      width: MediaQuery.of(context).size.width / 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // Transaction Type Text
                          Container(
                            child: Stack(
                              alignment: AlignmentDirectional(-1, 0),
                              children: <Widget>[
                                Text(
                                  text,
                                  textAlign: TextAlign.left,
                                  style: TextStyle(
                                    fontFamily: "NunitoSans",
                                    fontSize: AppFontSizes.small,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.transparent,
                                  ),
                                ),
                                Opacity(
                                  opacity: _opacityAnimation.value,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppColors.text45,
                                      borderRadius: BorderRadius.circular(100),
                                    ),
                                    child: Text(
                                      text,
                                      textAlign: TextAlign.left,
                                      style: TextStyle(
                                        fontFamily: "NunitoSans",
                                        fontSize: AppFontSizes.small - 4,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.transparent,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Amount Text
                          Container(
                            child: Stack(
                              alignment: AlignmentDirectional(-1, 0),
                              children: <Widget>[
                                Text(
                                  amount,
                                  textAlign: TextAlign.left,
                                  style: TextStyle(
                                      fontFamily: "NunitoSans",
                                      color: Colors.transparent,
                                      fontSize: AppFontSizes.smallest,
                                      fontWeight: FontWeight.w600),
                                ),
                                Opacity(
                                  opacity: _opacityAnimation.value,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppColors.primary20,
                                      borderRadius: BorderRadius.circular(100),
                                    ),
                                    child: Text(
                                      amount,
                                      textAlign: TextAlign.left,
                                      style: TextStyle(
                                          fontFamily: "NunitoSans",
                                          color: Colors.transparent,
                                          fontSize:
                                              AppFontSizes.smallest - 3,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Address Text
                Container(
                  width: MediaQuery.of(context).size.width / 2.4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Container(
                        child: Stack(
                          alignment: AlignmentDirectional(1, 0),
                          children: <Widget>[
                            Text(
                              address,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: AppFontSizes.smallest,
                                fontFamily: 'OverpassMono',
                                fontWeight: FontWeight.w100,
                                color: Colors.transparent,
                              ),
                            ),
                            Opacity(
                              opacity: _opacityAnimation.value,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.text20,
                                  borderRadius: BorderRadius.circular(100),
                                ),
                                child: Text(
                                  address,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: AppFontSizes.smallest - 3,
                                    fontFamily: 'OverpassMono',
                                    fontWeight: FontWeight.w100,
                                    color: Colors.transparent,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } //Dummy Transaction Card End

  //Main Card
  Widget _buildMainCard(BuildContext context, _scaffoldKey) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      margin: EdgeInsets.only(
          top: MediaQuery.of(context).size.height * 0.05,
          left: 14.0,
          right: 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Container(
            width: 70.0,
            height: 120.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  margin: EdgeInsets.only(top: 5, left: 5),
                  height: 50,
                  width: 50,
                  child: FlatButton(
                      onPressed: () {
                        _scaffoldKey.currentState.openDrawer();
                      },
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(50.0)),
                      padding: EdgeInsets.all(0.0),
                      child: Icon(AppIcons.settings,
                          color: AppColors.text, size: 24)),
                ),
              ],
            ),
          ),
          _getBalanceWidget(context),
          SizedBox(
            width: 70.0,
            height: 70.0,
          ),
        ],
      ),
    );
  } //Main Card

  // Get balance display
  Widget _getBalanceWidget(BuildContext context) {
    if (StateContainer.of(context).wallet.loading) {
      // Placeholder for balance text
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(
            child: Stack(
              alignment: AlignmentDirectional(0, 0),
              children: <Widget>[
                Text(
                  "1234567",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: "NunitoSans",
                      fontSize: AppFontSizes.small,
                      fontWeight: FontWeight.w600,
                      color: Colors.transparent),
                ),
                Opacity(
                  opacity: _opacityAnimation.value,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.text20,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      "1234567",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontFamily: "NunitoSans",
                          fontSize: AppFontSizes.small - 3,
                          fontWeight: FontWeight.w600,
                          color: Colors.transparent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width - 170),
            child: Stack(
              alignment: AlignmentDirectional(0, 0),
              children: <Widget>[
                AutoSizeText(
                  "12345678",
                  style: TextStyle(
                      fontFamily: "NunitoSans",
                      fontSize: AppFontSizes.largestc,
                      fontWeight: FontWeight.w900,
                      color: Colors.transparent),
                  maxLines: 1,
                  stepGranularity: 0.1,
                  minFontSize: 1,
                ),
                Opacity(
                  opacity: _opacityAnimation.value,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.primary60,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: AutoSizeText(
                      "12345678",
                      style: TextStyle(
                          fontFamily: "NunitoSans",
                          fontSize: AppFontSizes.largestc - 8,
                          fontWeight: FontWeight.w900,
                          color: Colors.transparent),
                      maxLines: 1,
                      stepGranularity: 0.1,
                      minFontSize: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            child: Stack(
              alignment: AlignmentDirectional(0, 0),
              children: <Widget>[
                Text(
                  "1234567",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: "NunitoSans",
                      fontSize: AppFontSizes.small,
                      fontWeight: FontWeight.w600,
                      color: Colors.transparent),
                ),
                Opacity(
                  opacity: _opacityAnimation.value,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.text20,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      "1234567",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontFamily: "NunitoSans",
                          fontSize: AppFontSizes.small - 3,
                          fontWeight: FontWeight.w600,
                          color: Colors.transparent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return GestureDetector(
      onTap: () {
        if (_priceConversion == PriceConversion.BTC) {
          // Hide prices
          setState(() {
            _convertedPriceStyle = AppStyles.TextStyleCurrencyAltHidden;
            _priceConversion = PriceConversion.NONE;
          });
          SharedPrefsUtil.inst.setPriceConversion(PriceConversion.NONE);
        } else {
          // Cycle to BTC price
          setState(() {
            _convertedPriceStyle = AppStyles.TextStyleCurrencyAlt;
            _priceConversion = PriceConversion.BTC;
          });
          SharedPrefsUtil.inst.setPriceConversion(PriceConversion.BTC);
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
              StateContainer.of(context).wallet.getLocalCurrencyPrice(
                  locale: StateContainer.of(context).currencyLocale),
              textAlign: TextAlign.center,
              style: _convertedPriceStyle),
          Container(
            margin: EdgeInsets.only(right: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Container(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width - 170),
                  child: AutoSizeText.rich(
                    TextSpan(
                      children: [
                        // Currency Icon
                        TextSpan(
                          text: "",
                          style: TextStyle(
                            fontFamily: 'AppIcons',
                            color: AppColors.primary,
                            fontSize: 25.0,
                          ),
                        ),
                        // Main balance text
                        TextSpan(
                          text: StateContainer.of(context)
                              .wallet
                              .getAccountBalanceDisplay(),
                          style: AppStyles.TextStyleCurrency,
                        ),
                      ],
                    ),
                    maxLines: 1,
                    style: TextStyle(fontSize: 28.0),
                    stepGranularity: 0.1,
                    minFontSize: 1,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: <Widget>[
              Icon(
                  AppIcons.btc,
                  color: _priceConversion == PriceConversion.NONE
                      ? Colors.transparent
                      : AppColors.text60,
                  size: 14),
              Text(
                  StateContainer.of(context).wallet.btcPrice,
                  textAlign: TextAlign.center,
                  style: _convertedPriceStyle),
            ],
          ),
        ],
      ),
    );
  }
}

class TransactionDetailsSheet {
  String _hash;
  String _address;
  String _displayName;
  TransactionDetailsSheet(String hash, String address, String displayName)
      : _hash = hash,
        _address = address,
        _displayName = displayName;
  // Current state references
  bool _addressCopied = false;
  // Timer reference so we can cancel repeated events
  Timer _addressCopiedTimer;

  mainBottomSheet(BuildContext context) {
    AppSheets.showAppHeightEightSheet(
        context: context,
        builder: (BuildContext context) {
          return StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
            return Container(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Column(
                    children: <Widget>[
                      // A stack for Copy Address and Add Contact buttons
                      Stack(
                        children: <Widget>[
                          // A row for Copy Address Button
                          Row(
                            children: <Widget>[
                              AppButton.buildAppButton(
                                // Share Address Button
                                _addressCopied ? AppButtonType.SUCCESS : AppButtonType.PRIMARY,
                                _addressCopied ? AppLocalization.of(context).addressCopied : AppLocalization.of(context).copyAddress,
                                Dimens.BUTTON_TOP_EXCEPTION_DIMENS,
                                onPressed: () {
                                  Clipboard.setData(
                                      new ClipboardData(text: _address));
                                  setState(() {
                                    // Set copied style
                                    _addressCopied = true;
                                  });
                                  if (_addressCopiedTimer != null) {
                                    _addressCopiedTimer.cancel();
                                  }
                                  _addressCopiedTimer = new Timer(
                                      const Duration(milliseconds: 800),
                                      () {
                                    setState(() {
                                      _addressCopied = false;
                                    });
                                  });
                                }
                              ),
                            ],
                          ),
                          // A row for Add Contact Button
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Container(
                                margin: EdgeInsets.only(
                                    top: Dimens.BUTTON_TOP_EXCEPTION_DIMENS[1],
                                    right:
                                        Dimens.BUTTON_TOP_EXCEPTION_DIMENS[2]),
                                child: Container(
                                  height: 55,
                                  width: 55,
                                  // Add Contact Button
                                  child: !_displayName.startsWith("@")
                                      ? FlatButton(
                                          onPressed: () {
                                            Navigator.of(context).pop();
                                            AddContactSheet(address: _address)
                                                .mainBottomSheet(context);
                                          },
                                          splashColor: Colors.transparent,
                                          highlightColor: Colors.transparent,
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(100.0)),
                                          padding: EdgeInsets.symmetric(
                                              vertical: 10.0, horizontal: 10),
                                          child: Icon(AppIcons.addcontact,
                                              size: 35,
                                              color: _addressCopied
                                                  ? AppColors.successDark
                                                  : AppColors
                                                      .backgroundDark),
                                        )
                                      : SizedBox(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      // A row for View Details button
                      Row(
                        children: <Widget>[
                          AppButton.buildAppButton(
                              AppButtonType.PRIMARY_OUTLINE,
                              AppLocalization.of(context).viewDetails,
                              Dimens.BUTTON_BOTTOM_DIMENS, onPressed: () {
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (BuildContext context) {
                              return UIUtil.showBlockExplorerWebview(
                                  context, _hash);
                            }));
                          }),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            );
          });
        });
  }
}