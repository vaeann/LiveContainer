//
//  ResizeHandleView.h
//  LiveContainer
//
//  Created by Duy Tran on 2/6/25.
//
#import <UIKit/UIKit.h>

@interface ResizeHandleView : UIView
// 半透明白三角（楔形）子视图。藏掉它只影响外观：把手视图本身
// 保持 alpha 1，44×44 的命中/手势区域不变，照样能点能拖。
@property(nonatomic, readonly) UIView *wedgeView;
- (instancetype)initWithFrame:(CGRect)frame;
@end
